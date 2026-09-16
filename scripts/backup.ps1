# Sauvegarde chiffrée → dépôt GitHub privé.
# Contenu : base Postiz + base Temporal (pg_dump) + JWT_SECRET. Médias exclus par défaut.
#
#   powershell -ExecutionPolicy Bypass -File scripts\backup.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\backup.ps1 -WithUploads   (inclut data\uploads, peut être lourd)
#   powershell -ExecutionPolicy Bypass -File scripts\backup.ps1 -NoPush        (commit local seulement)

param([switch]$WithUploads, [switch]$NoPush, [int]$Keep = 30)

. "$PSScriptRoot\lib\common.ps1"

Assert-Docker
$cfg = Read-DotEnv
if (-not (Test-ContainerRunning 'postiz-postgres')) { Fail "postiz-postgres n'est pas démarré : rien à sauvegarder. Lance start.ps1 d'abord." }
Assert-BackupsRepo
$pass = Get-Passphrase

$ts   = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $env:TEMP "postiz-backup-$ts"
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    Write-Step "Dump des bases"
    docker exec postiz-postgres pg_dump -U $cfg.POSTGRES_USER -d $cfg.POSTGRES_DB -Fc -f /tmp/postiz.dump
    if ($LASTEXITCODE -ne 0) { Fail "pg_dump Postiz échoué" }
    docker cp postiz-postgres:/tmp/postiz.dump (Join-Path $work 'postiz.dump') | Out-Null
    docker exec postiz-postgres rm -f /tmp/postiz.dump

    if (Test-ContainerRunning 'temporal-postgresql') {
        docker exec temporal-postgresql pg_dumpall -U temporal -f /tmp/temporal.sql
        if ($LASTEXITCODE -ne 0) { Fail "pg_dumpall Temporal échoué" }
        docker cp temporal-postgresql:/tmp/temporal.sql (Join-Path $work 'temporal.sql') | Out-Null
        docker exec temporal-postgresql rm -f /tmp/temporal.sql
    } else { Write-Warn2 "temporal-postgresql arrêté : base Temporal non sauvegardée" }

    Set-Content (Join-Path $work 'secrets.env') @("JWT_SECRET=$($cfg.JWT_SECRET)", "FUNNEL_HOST=$($cfg.FUNNEL_HOST)") -Encoding ASCII

    if ($WithUploads) {
        Write-Step "Archive des médias (data\uploads)"
        $up = Join-Path $DataDir 'uploads'
        docker run --rm --entrypoint tar -v "${up}:/u:ro" -v "${work}:/work" $OpensslImage czf /work/uploads.tar.gz -C /u .
        if ($LASTEXITCODE -ne 0) { Fail "Archive des médias échouée" }
    }

    Write-Step "Chiffrement"
    $files = @('postiz.dump', 'secrets.env')
    if (Test-Path (Join-Path $work 'temporal.sql')) { $files += 'temporal.sql' }
    if ($WithUploads) { $files += 'uploads.tar.gz' }
    foreach ($f in $files) { Protect-File $work $f "$f.enc" $pass; Remove-Item (Join-Path $work $f) }

    Write-Step "Écriture dans le dépôt"
    $latest = Join-Path $BackupsRepo 'latest'
    $hist   = Join-Path $BackupsRepo "history\$ts"
    New-Item -ItemType Directory -Force -Path $latest, $hist | Out-Null
    Get-ChildItem $latest -File | Remove-Item -Force
    foreach ($f in $files) {
        Copy-Item (Join-Path $work "$f.enc") (Join-Path $latest "$f.enc")
        if ($f -ne 'uploads.tar.gz') { Copy-Item (Join-Path $work "$f.enc") (Join-Path $hist "$f.enc") }
    }
    $manifest = @{
        date = (Get-Date).ToString('o'); machine = $env:COMPUTERNAME; funnelHost = $cfg.FUNNEL_HOST
        files = $files; cipher = 'aes-256-cbc pbkdf2 iter=200000 (openssl enc)'
    } | ConvertTo-Json
    Set-Content (Join-Path $latest 'manifest.json') $manifest -Encoding UTF8
    Set-Content (Join-Path $hist 'manifest.json') $manifest -Encoding UTF8

    # rotation
    $old = Get-ChildItem (Join-Path $BackupsRepo 'history') -Directory | Sort-Object Name -Descending | Select-Object -Skip $Keep
    foreach ($d in $old) { Remove-Item -Recurse -Force $d.FullName }

    Push-Location $BackupsRepo
    try {
        git add -A
        git -c user.name="postiz-backup" -c user.email="postiz-backup@localhost" commit -q -m "backup $ts from $env:COMPUTERNAME" 2>$null
        if ($NoPush) { Write-Ok "Commit local (pas de push)" }
        else {
            git push -q origin HEAD
            if ($LASTEXITCODE -ne 0) { Fail "git push échoué (réseau ? gh auth ?). La sauvegarde est committée localement, relance backup.ps1 plus tard." }
            Write-Ok "Sauvegarde $ts poussée sur GitHub"
        }
    } finally { Pop-Location }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
