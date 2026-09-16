# Démarre Postiz, l'expose via Tailscale Funnel, bloque la mise en veille,
# ouvre le navigateur, puis reste au premier plan. Ctrl+C = arrêt propre (stop.ps1).
#
#   powershell -ExecutionPolicy Bypass -File scripts\start.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\start.ps1 -Detach   (rend la main, sans anti-veille)

param([switch]$Detach)

. "$PSScriptRoot\lib\common.ps1"

# --- anti-veille (Windows) ---
Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
$ES_CONTINUOUS = [uint32]0x80000000
$ES_SYSTEM_REQUIRED = [uint32]0x00000001

Write-Step "Vérifications"
Assert-Docker
$cfg = Read-DotEnv
$funnelHost = Get-FunnelHost
$port = $cfg.POSTIZ_PORT
if (-not $port) { $port = '4007' }
if ($cfg.FUNNEL_HOST -ne $funnelHost) {
    Fail "FUNNEL_HOST dans .env ($($cfg.FUNNEL_HOST)) ≠ nom Tailscale actuel ($funnelHost). Corrige .env (et les redirect URIs des réseaux) avant de démarrer."
}
if (-not $cfg.JWT_SECRET) { Fail "JWT_SECRET vide dans .env. Lance scripts\setup.ps1." }

# port local libre ? (le port est fixe : il fait partie des URLs déclarées chez les réseaux)
$busy = Get-NetTCPConnection -LocalPort ([int]$port) -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -ne 0 -and (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName -notmatch 'com.docker|vpnkit|wslrelay' }
if ($busy) { Fail "Le port $port est utilisé par '$((Get-Process -Id $busy[0].OwningProcess).ProcessName)'. Ferme cette application puis relance." }

Write-Step "Démarrage des conteneurs"
Compose up -d --remove-orphans

Write-Step "Attente que Postiz soit prêt (jusqu'à 5 min au premier démarrage)"
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep 5
    $h = docker inspect -f '{{.State.Health.Status}}' postiz 2>$null
    Write-Host "    état : $h"
} while ($h -ne 'healthy' -and (Get-Date) -lt $deadline)
if ($h -ne 'healthy') {
    Write-Warn2 "Postiz n'est pas 'healthy'. Logs : docker compose logs -f postiz"
}

Write-Step "Exposition publique HTTPS (Tailscale Funnel)"
& $Tailscale funnel --bg --set-path /legal $LegalDir | Out-Null
& $Tailscale funnel --bg $port | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "Funnel refusé. Vérifie dans la console Tailscale : MagicDNS + HTTPS activés, et l'attribut 'funnel' dans Access Controls."
} else {
    Write-Ok "https://$funnelHost  →  127.0.0.1:$port"
}

Write-Step "Posts en retard ?"
try {
    $sql = 'SELECT count(*) FROM "Post" WHERE "publishDate" < now() AND state = ''QUEUE'' AND "deletedAt" IS NULL AND "parentPostId" IS NULL;'
    $n = ($sql | docker exec -i postiz-postgres psql -U $cfg.POSTGRES_USER -d $cfg.POSTGRES_DB -tA 2>$null) -join ''
    if ($n -match '^\d+$' -and [int]$n -gt 0) {
        Write-Warn2 "$n post(s) dont l'heure est passée pendant que le PC était éteint. Ouvre le calendrier et republie/reprogramme-les."
    } else { Write-Ok "Aucun post en retard" }
} catch { Write-Warn2 "Vérification impossible ($_)" }

Start-Process "https://$funnelHost"

if ($Detach) {
    Write-Host "`nPostiz tourne en arrière-plan. Pour arrêter : scripts\stop.ps1`n" -ForegroundColor Green
    exit 0
}

[Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
Write-Host @"

  Postiz est en ligne : https://$funnelHost
  Mise en veille bloquée tant que cette fenêtre est ouverte (ferme le capot = veille quand même : garde le PC branché et ouvert).
  Ctrl+C ici = sauvegarde + arrêt propre.

"@ -ForegroundColor Green

try {
    while (Test-ContainerRunning 'postiz') { Start-Sleep 10 }
    Write-Warn2 "Le conteneur postiz s'est arrêté tout seul. Logs : docker compose logs postiz"
} finally {
    [Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    Write-Host "`nArrêt demandé…"
    & "$PSScriptRoot\stop.ps1"
}
