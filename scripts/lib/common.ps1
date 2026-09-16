# Fonctions partagées par tous les scripts (Windows PowerShell 5.1 compatible).
# Chargé par : . "$PSScriptRoot\lib\common.ps1"

$ErrorActionPreference = 'Stop'

# --- Chemins ---------------------------------------------------------------
$script:StackDir     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:EnvFile      = Join-Path $StackDir '.env'
$script:EnvExample   = Join-Path $StackDir '.env.example'
$script:DataDir      = Join-Path $StackDir 'data'
$script:LegalDir     = Join-Path $StackDir 'legal'
$script:BackupsRepo  = Join-Path $StackDir 'backups-repo'
$script:LocalState   = Join-Path $env:LOCALAPPDATA 'postiz-stack'
$script:PassFile     = Join-Path $LocalState 'passphrase.dpapi'
$script:Tailscale    = 'C:\Program Files\Tailscale\tailscale.exe'
$script:OpensslImage = 'alpine/openssl'
$script:BackupsRepoName = 'postiz-backups'

# --- Affichage ---------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    !!  $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "`nERREUR : $msg" -ForegroundColor Red; exit 1 }

# --- .env ---------------------------------------------------------------------
function Read-DotEnv {
    if (-not (Test-Path $EnvFile)) { Fail ".env introuvable. Lance d'abord scripts\setup.ps1" }
    $h = @{}
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $k, $v = $line -split '=', 2
        $h[$k.Trim()] = $v.Trim()
    }
    # résout ${VAR} en une passe (suffit pour ce fichier)
    foreach ($k in @($h.Keys)) {
        $h[$k] = [regex]::Replace($h[$k], '\$\{(\w+)\}', {
            param($m)
            $name = $m.Groups[1].Value
            if ($h.ContainsKey($name)) { $h[$name] } else { '' }
        })
    }
    return $h
}

function Set-DotEnvValue($key, $value) {
    $lines = Get-Content $EnvFile
    $found = $false
    $out = foreach ($l in $lines) {
        if ($l -match "^\s*$([regex]::Escape($key))=") { $found = $true; "$key=$value" } else { $l }
    }
    if (-not $found) { $out += "$key=$value" }
    Set-Content -Path $EnvFile -Value $out -Encoding UTF8
}

# --- Docker ---------------------------------------------------------------------
function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Fail "Docker n'est pas installé. Installe Docker Desktop : https://docs.docker.com/desktop/install/windows-install/"
    }
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Docker Desktop n'est pas démarré, tentative de lancement..."
        $exe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $exe) { Start-Process $exe }
        $deadline = (Get-Date).AddSeconds(120)
        do { Start-Sleep 5; docker info *> $null } while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
        if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop ne répond pas après 2 min. Lance-le à la main puis réessaie." }
    }
    Write-Ok "Docker prêt"
}

function Test-ContainerRunning($name) {
    $s = docker inspect -f '{{.State.Running}}' $name 2>$null
    return ($LASTEXITCODE -eq 0 -and "$s" -eq 'true')
}

function Compose {
    Push-Location $StackDir
    try {
        docker compose @args
        if ($LASTEXITCODE -ne 0) { Fail "docker compose $($args -join ' ') a échoué" }
    } finally { Pop-Location }
}

# --- Tailscale -----------------------------------------------------------------------
function Assert-Tailscale {
    if (-not (Test-Path $Tailscale)) { Fail "Tailscale n'est pas installé : https://tailscale.com/download/windows" }
    $raw = & $Tailscale status --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { Fail "Tailscale ne répond pas. Ouvre Tailscale et connecte-toi." }
    $st = ($raw -join "`n") | ConvertFrom-Json
    if ($st.BackendState -ne 'Running') { Fail "Tailscale n'est pas connecté (état : $($st.BackendState))." }
    return $st
}

function Get-FunnelHost {
    $st = Assert-Tailscale
    $name = [string]$st.Self.DNSName
    if (-not $name) { Fail "Impossible de lire le nom MagicDNS. Active MagicDNS dans la console Tailscale (DNS > MagicDNS)." }
    return $name.TrimEnd('.')
}

# --- Passphrase (DPAPI : lisible uniquement par TON compte Windows) ----------------
function ConvertTo-Plain([securestring]$s) {
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Get-Passphrase([switch]$Create) {
    if ((Test-Path $PassFile) -and -not $Create) {
        return ConvertTo-Plain (Get-Content $PassFile | ConvertTo-SecureString)
    }
    Write-Host ""
    Write-Host "Passphrase de chiffrement des sauvegardes." -ForegroundColor Yellow
    Write-Host "C'est la SEULE chose à ne jamais perdre : sans elle, les sauvegardes sont illisibles."
    Write-Host "Note-la dans un gestionnaire de mots de passe."
    do {
        $a = Read-Host -AsSecureString "Passphrase (12 caractères minimum)"
        $b = Read-Host -AsSecureString "Confirme la passphrase"
        $pa = ConvertTo-Plain $a
        $pb = ConvertTo-Plain $b
        if ($pa -ne $pb) { Write-Warn2 "Les deux saisies diffèrent." }
        elseif ($pa.Length -lt 12) { Write-Warn2 "Trop courte." }
    } while ($pa -ne $pb -or $pa.Length -lt 12)
    New-Item -ItemType Directory -Force -Path $LocalState | Out-Null
    $a | ConvertFrom-SecureString | Set-Content -Path $PassFile
    Write-Ok "Passphrase enregistrée (chiffrée DPAPI) dans $PassFile"
    return $pa
}

# --- Chiffrement via conteneur (aucun openssl à installer sur le PC) ----------------
# Travaille sur des fichiers dans un même dossier monté : pas de pipe,
# PowerShell 5.1 abîme les flux binaires.
function Invoke-Openssl($workDir, $pass, [string[]]$opensslArgs) {
    $env:POSTIZ_BACKUP_PASS = $pass
    try {
        docker run --rm -e POSTIZ_BACKUP_PASS -v "${workDir}:/work" -w /work $OpensslImage @opensslArgs
        return $LASTEXITCODE
    } finally { Remove-Item Env:\POSTIZ_BACKUP_PASS -ErrorAction SilentlyContinue }
}

function Protect-File($workDir, $inName, $outName, $pass) {
    $rc = Invoke-Openssl $workDir $pass @('enc','-aes-256-cbc','-pbkdf2','-iter','200000','-salt','-pass','env:POSTIZ_BACKUP_PASS','-in',$inName,'-out',$outName)
    if ($rc -ne 0) { Fail "Chiffrement de $inName échoué" }
}

function Unprotect-File($workDir, $inName, $outName, $pass) {
    $rc = Invoke-Openssl $workDir $pass @('enc','-d','-aes-256-cbc','-pbkdf2','-iter','200000','-pass','env:POSTIZ_BACKUP_PASS','-in',$inName,'-out',$outName)
    if ($rc -ne 0) { Fail "Déchiffrement de $inName échoué : mauvaise passphrase ?" }
}

function Test-Crypto($pass) {
    $tmp = Join-Path $env:TEMP "postiz-crypto-test"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Set-Content (Join-Path $tmp 'plain.txt') 'postiz-crypto-ok' -NoNewline
    Protect-File $tmp 'plain.txt' 'plain.enc' $pass
    Unprotect-File $tmp 'plain.enc' 'back.txt' $pass
    $ok = (Get-Content (Join-Path $tmp 'back.txt') -Raw) -eq 'postiz-crypto-ok'
    Remove-Item -Recurse -Force $tmp
    if (-not $ok) { Fail "Le test de chiffrement aller-retour a échoué." }
    Write-Ok "Chiffrement vérifié (aller-retour)"
}

# --- GitHub (dépôt privé de sauvegardes) ----------------------------------------------
function Assert-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail "GitHub CLI (gh) manquant : https://cli.github.com" }
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { Fail "gh n'est pas connecté. Lance : gh auth login" }
}

function Get-GhUser { return (gh api user --jq .login).Trim() }

function Assert-BackupsRepo {
    if (Test-Path (Join-Path $BackupsRepo '.git')) { return }
    Assert-Gh
    $user = Get-GhUser
    gh repo view "$user/$BackupsRepoName" *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Création du dépôt PRIVÉ $user/$BackupsRepoName"
        gh repo create $BackupsRepoName --private --description "Sauvegardes chiffrées Postiz (AES-256)" | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "Création du dépôt de sauvegardes impossible" }
    }
    $vis = (gh repo view "$user/$BackupsRepoName" --json visibility --jq .visibility).Trim()
    if ($vis -ne 'PRIVATE') { Fail "Le dépôt $user/$BackupsRepoName n'est pas privé ($vis). Rends-le privé avant de continuer." }
    gh repo clone "$user/$BackupsRepoName" $BackupsRepo | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Clone du dépôt de sauvegardes impossible" }
    Write-Ok "Dépôt de sauvegardes prêt : $BackupsRepo"
}
