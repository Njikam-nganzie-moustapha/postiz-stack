# Première configuration de TON instance Postiz. À lancer une seule fois.
# Ne démarre rien : prépare .env, la passphrase, le dépôt de sauvegardes,
# télécharge les images Docker et propose une restauration si une sauvegarde existe.
#
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -SkipPull   (ne télécharge pas les images)

param([switch]$SkipPull)

. "$PSScriptRoot\lib\common.ps1"

Write-Host @"

  Postiz — configuration initiale
  ==============================
  Poids à prévoir : ~1,4 GB à télécharger, 3,5-4 GB sur disque, ~1,5 GB de RAM en marche.

"@ -ForegroundColor White

Write-Step "1/6 Vérifications"
Assert-Docker
$funnelHost = Get-FunnelHost
Write-Ok "Tailscale connecté — nom public : $funnelHost"

Write-Step "2/6 Fichier .env"
if (Test-Path $EnvFile) {
    Write-Warn2 ".env existe déjà, il est conservé (supprime-le pour repartir de zéro)."
} else {
    Copy-Item $EnvExample $EnvFile
    Set-DotEnvValue 'FUNNEL_HOST' $funnelHost
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    Set-DotEnvValue 'JWT_SECRET' ([Convert]::ToBase64String($bytes) -replace '[/+=]', '')
    Write-Ok ".env créé (FUNNEL_HOST et JWT_SECRET remplis)"
}
$cfg = Read-DotEnv
if ($cfg.FUNNEL_HOST -ne $funnelHost) {
    Write-Warn2 "FUNNEL_HOST dans .env ($($cfg.FUNNEL_HOST)) ≠ nom Tailscale actuel ($funnelHost)."
    Write-Warn2 "Si tu as changé de PC, mets à jour FUNNEL_HOST et les redirect URIs de chaque réseau."
}

Write-Step "3/6 Passphrase des sauvegardes"
$hadPass = Test-Path $PassFile
$pass = Get-Passphrase
if ($hadPass) { Write-Ok "Passphrase déjà enregistrée" }

Write-Step "4/6 Dépôt GitHub privé des sauvegardes"
Assert-BackupsRepo

Write-Step "5/6 Images Docker"
if ($SkipPull) {
    Write-Warn2 "Téléchargement sauté (-SkipPull). start.ps1 le fera au premier lancement."
} else {
    Write-Host "    Téléchargement (~1,4 GB)… tu peux laisser tourner."
    Compose pull
    docker pull $OpensslImage | Out-Null
    Test-Crypto $pass
}

Write-Step "6/6 Sauvegarde existante ?"
$latest = Join-Path $BackupsRepo 'latest\postiz.dump.enc'
$dbDir  = Join-Path $DataDir 'postgres'
if ((Test-Path $latest) -and -not (Test-Path $dbDir)) {
    Write-Host "    Une sauvegarde existe dans ton dépôt et cette machine est vierge."
    $r = Read-Host "    Restaurer maintenant ? (o/N)"
    if ($r -match '^[oOyY]') { & "$PSScriptRoot\restore.ps1" }
} else {
    Write-Ok "Rien à restaurer"
}

Write-Host @"

  Configuration terminée.

  Avant le premier start, dans la console Tailscale (https://login.tailscale.com/admin) :
    - DNS  : MagicDNS activé, HTTPS Certificates activé
    - Access Controls : ajouter
        "nodeAttrs": [ { "target": ["autogroup:member"], "attr": ["funnel"] } ]

  Ensuite :  powershell -ExecutionPolicy Bypass -File scripts\start.ps1
  Ton Postiz sera à : https://$funnelHost

"@ -ForegroundColor Green
