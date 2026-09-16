# Arrêt propre : sauvegarde → coupe Funnel → arrête les conteneurs → nettoie les caches Docker.
# Ne supprime JAMAIS les images (pas de `docker system prune`) : rien à re-télécharger au prochain start.
#
#   powershell -ExecutionPolicy Bypass -File scripts\stop.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\stop.ps1 -NoBackup

param([switch]$NoBackup)

. "$PSScriptRoot\lib\common.ps1"

if (-not $NoBackup -and (Test-ContainerRunning 'postiz-postgres')) {
    Write-Step "Sauvegarde avant arrêt"
    try { & "$PSScriptRoot\backup.ps1" } catch { Write-Warn2 "Sauvegarde échouée : $_ — arrêt quand même." }
}

Write-Step "Fermeture de l'accès public"
if (Test-Path $Tailscale) { & $Tailscale funnel reset 2>$null | Out-Null }

Write-Step "Arrêt des conteneurs"
Compose down --remove-orphans

Write-Step "Nettoyage (caches uniquement, images conservées)"
docker image prune -f | Out-Null
docker builder prune -f | Out-Null

Write-Host "`nPostiz arrêté.`n" -ForegroundColor Green
