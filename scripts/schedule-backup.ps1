# Crée (ou supprime) une tâche planifiée Windows : sauvegarde chiffrée chaque jour à 03:00
# si Postiz tourne à ce moment-là. S'exécute sous TON compte (la passphrase DPAPI n'est lisible que par lui).
#
#   powershell -ExecutionPolicy Bypass -File scripts\schedule-backup.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\schedule-backup.ps1 -Remove
#   powershell -ExecutionPolicy Bypass -File scripts\schedule-backup.ps1 -At 22:30

param([switch]$Remove, [string]$At = '03:00')

. "$PSScriptRoot\lib\common.ps1"

$taskName = 'Postiz backup'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok "Tâche '$taskName' supprimée"
    exit 0
}

$backup = Join-Path $PSScriptRoot 'backup.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$backup`""
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Ok "Tâche '$taskName' : tous les jours à $At (ne fait rien si Postiz est arrêté)"
