# Restaure la dernière sauvegarde du dépôt GitHub privé sur CE PC.
# À utiliser sur une machine vierge (après setup.ps1) ou après un crash.
#
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -Force   (écrase une base existante)

param([switch]$Force)

. "$PSScriptRoot\lib\common.ps1"

Assert-Docker
$cfg = Read-DotEnv
Assert-BackupsRepo
$pass = Get-Passphrase

Write-Step "Récupération de la dernière sauvegarde"
Push-Location $BackupsRepo
try { git pull -q origin HEAD 2>$null } finally { Pop-Location }
$latest = Join-Path $BackupsRepo 'latest'
if (-not (Test-Path (Join-Path $latest 'postiz.dump.enc'))) { Fail "Aucune sauvegarde dans $latest" }
Get-Content (Join-Path $latest 'manifest.json') | Write-Host

$dbDir = Join-Path $DataDir 'postgres'
if ((Test-Path $dbDir) -and (Get-ChildItem $dbDir -Force | Select-Object -First 1) -and -not $Force) {
    Fail "data\postgres n'est pas vide. Relance avec -Force pour ÉCRASER la base actuelle (fais un backup.ps1 avant si elle compte)."
}

$work = Join-Path $env:TEMP "postiz-restore-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    Write-Step "Déchiffrement"
    foreach ($f in (Get-ChildItem $latest -Filter '*.enc')) {
        Copy-Item $f.FullName (Join-Path $work $f.Name)
        Unprotect-File $work $f.Name ($f.Name -replace '\.enc$', '') $pass
        Remove-Item (Join-Path $work $f.Name)
    }

    Write-Step "Secrets"
    $sec = @{}
    foreach ($l in Get-Content (Join-Path $work 'secrets.env')) { $k, $v = $l -split '=', 2; $sec[$k] = $v }
    if ($sec.JWT_SECRET -and $sec.JWT_SECRET -ne $cfg.JWT_SECRET) {
        Set-DotEnvValue 'JWT_SECRET' $sec.JWT_SECRET
        Write-Ok "JWT_SECRET restauré (nécessaire pour déchiffrer les comptes liés)"
    }
    if ($sec.FUNNEL_HOST -and $sec.FUNNEL_HOST -ne $cfg.FUNNEL_HOST) {
        Write-Warn2 "La sauvegarde vient de https://$($sec.FUNNEL_HOST), ce PC est https://$($cfg.FUNNEL_HOST)."
        Write-Warn2 "Mets à jour la redirect URI chez chaque réseau social, sinon 'reconnecter un compte' échouera."
    }

    Write-Step "Bases de données"
    if ($Force) { Compose down; Remove-Item -Recurse -Force $dbDir, (Join-Path $DataDir 'temporal-postgres') -ErrorAction SilentlyContinue }
    Compose up -d postiz-postgres temporal-postgresql
    Compose exec -T postiz-postgres sh -c 'until pg_isready -q; do sleep 1; done'

    docker cp (Join-Path $work 'postiz.dump') postiz-postgres:/tmp/postiz.dump | Out-Null
    docker exec postiz-postgres pg_restore -U $cfg.POSTGRES_USER -d $cfg.POSTGRES_DB --clean --if-exists --no-owner /tmp/postiz.dump
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "pg_restore a signalé des avertissements (souvent bénins : objets absents avec --clean)." }
    docker exec postiz-postgres rm -f /tmp/postiz.dump
    Write-Ok "Base Postiz restaurée"

    if (Test-Path (Join-Path $work 'temporal.sql')) {
        Compose exec -T temporal-postgresql sh -c 'until pg_isready -q -U temporal; do sleep 1; done'
        docker cp (Join-Path $work 'temporal.sql') temporal-postgresql:/tmp/temporal.sql | Out-Null
        docker exec temporal-postgresql psql -U temporal -q -f /tmp/temporal.sql 2>$null | Out-Null
        docker exec temporal-postgresql rm -f /tmp/temporal.sql
        Write-Ok "Base Temporal restaurée"
    }

    if (Test-Path (Join-Path $work 'uploads.tar.gz')) {
        Write-Step "Médias"
        $up = Join-Path $DataDir 'uploads'
        New-Item -ItemType Directory -Force -Path $up | Out-Null
        docker run --rm --entrypoint tar -v "${up}:/u" -v "${work}:/work:ro" $OpensslImage xzf /work/uploads.tar.gz -C /u
        Write-Ok "Médias restaurés dans data\uploads"
    } else {
        Write-Warn2 "Pas de médias dans la sauvegarde : les posts programmés avec une vidéo devront être re-uploadés."
    }

    Compose stop
    Write-Host "`nRestauration terminée. Lance scripts\start.ps1`n" -ForegroundColor Green
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
