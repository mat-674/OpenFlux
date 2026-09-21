# OpenFlux installer for Windows — clone, install deps, build, install binary.
#
# One-liner:
#   irm https://raw.githubusercontent.com/mat-674/OpenFlux/main/install.ps1 | iex
#
# Overridable via env:
#   $env:OPENFLUX_REPO     git URL             (default: https://github.com/mat-674/OpenFlux.git)
#   $env:OPENFLUX_REF      branch/tag/commit   (default: main)
#   $env:OPENFLUX_SRC      source checkout dir (default: $env:USERPROFILE\.openflux\src)
#   $env:OPENFLUX_PREFIX   install dir         (default: $env:LOCALAPPDATA\OpenFlux\bin)
#   $env:OPENFLUX_BIN      binary name         (default: openflux)

$ErrorActionPreference = 'Stop'

$Repo    = if ($env:OPENFLUX_REPO)   { $env:OPENFLUX_REPO }   else { 'https://github.com/mat-674/OpenFlux.git' }
$Ref     = if ($env:OPENFLUX_REF)    { $env:OPENFLUX_REF }    else { 'main' }
$SrcDir  = if ($env:OPENFLUX_SRC)    { $env:OPENFLUX_SRC }    else { Join-Path $env:USERPROFILE '.openflux\src' }
$DestDir = if ($env:OPENFLUX_PREFIX) { $env:OPENFLUX_PREFIX } else { Join-Path $env:LOCALAPPDATA 'OpenFlux\bin' }
$BinName = if ($env:OPENFLUX_BIN)    { $env:OPENFLUX_BIN }    else { 'openflux' }
$ExeName = "$BinName.exe"

function Log($m)  { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Progress -Activity 'OpenFlux installer' -Completed; Write-Host "xx  $m" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------- progress ---
$Step = 0
$StepTotal = 6

function Start-Stage($Title) {
    $script:Step++
    Write-Host ''
    Write-Host "[$script:Step/$script:StepTotal] $Title" -ForegroundColor Cyan
    Write-Progress -Activity 'OpenFlux installer' -Status "[$script:Step/$script:StepTotal] $Title" `
        -PercentComplete ([int](100 * ($script:Step - 1) / $script:StepTotal))
}

function Complete-Stage($Title) {
    Write-Host "      done: $Title" -ForegroundColor DarkGray
}

# Runs one stage: header, live output (child processes write straight to the
# console), timing, and a readable failure dump.
function Invoke-Stage($Title, [scriptblock]$Action) {
    Start-Stage $Title
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { & $Action }
    catch {
        Write-Progress -Activity 'OpenFlux installer' -Completed
        Write-Host ("      FAILED ({0:n1}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
        Write-Host ''
        Die $Title
    }
    Complete-Stage "$Title ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)"
}

# ----------------------------------------------------------------- tooling ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die 'git is required. Install it with: winget install Git.Git'
}

function Get-Go {
    $go = Get-Command go -ErrorAction SilentlyContinue
    if ($go) { Log "found $(& go version)"; return $go.Source }

    Log 'Go not found - installing via winget'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die 'Go is required and winget is unavailable. Install Go from https://go.dev/dl/ and re-run.'
    }
    winget install --id GoLang.Go -e --accept-source-agreements --accept-package-agreements | Out-Null

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Go\bin\go.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Go\bin\go.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    Die 'Go installed but not found on PATH. Open a new shell and re-run.'
}

# -------------------------------------------------------------------- main ---
$ScriptStart = Get-Date
Write-Host 'OpenFlux installer' -NoNewline
Write-Host " (windows, ref $Ref)" -ForegroundColor DarkGray

$Go = $null

Invoke-Stage 'Checking prerequisites (git, PATH)' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required. Install it with: winget install Git.Git'
    }
}

Invoke-Stage 'Preparing the Go toolchain' { $script:Go = Get-Go }

Invoke-Stage "Fetching sources ($Ref)" {
    $here = (Get-Location).Path
    if ((Test-Path (Join-Path $here 'go.mod')) -and
        ((Get-Content (Join-Path $here 'go.mod') -TotalCount 1) -match '^module openflux')) {
        $script:SrcDir = $here
        Write-Host "using the current checkout: $script:SrcDir" -ForegroundColor DarkGray
        return
    }
    if (Test-Path (Join-Path $SrcDir '.git')) {
        Write-Host "updating $Script:SrcDir"
        # No --progress: git writes its own progress straight to this console
        # when stderr is a terminal, and stays quiet when output is piped.
        git -C $SrcDir fetch --depth 1 origin $Ref
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
        git -C $SrcDir checkout -q FETCH_HEAD
    }
    else {
        Write-Host "cloning $Ref -> $SrcDir"
        New-Item -ItemType Directory -Force -Path (Split-Path $SrcDir) | Out-Null
        git clone --depth 1 --branch $Ref $Repo $SrcDir
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -Recurse -Force $SrcDir -ErrorAction SilentlyContinue
            Write-Host "ref '$Ref' is not a branch/tag, doing a full clone" -ForegroundColor DarkGray
            git clone $Repo $SrcDir
            if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
            git -C $SrcDir checkout -q $Ref
        }
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
}

Invoke-Stage 'Resolving dependencies (go mod download)' {
    Push-Location $SrcDir
    try {
        & $Go mod download
        if ($LASTEXITCODE -ne 0) { throw "go mod download failed" }
    }
    finally { Pop-Location }
}

Invoke-Stage 'Compiling (go build -trimpath -ldflags="-s -w")' {
    Push-Location $SrcDir
    try {
        $env:CGO_ENABLED = '0'
        & $Go build -trimpath -ldflags '-s -w' -o $ExeName .
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
        if (-not (Test-Path (Join-Path $SrcDir $ExeName))) { throw "build produced no binary" }
    }
    finally { Pop-Location }
}

Invoke-Stage "Installing to $DestDir" {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    Copy-Item (Join-Path $SrcDir $ExeName) (Join-Path $DestDir $ExeName) -Force
    Write-Host "placed $DestDir\$ExeName" -ForegroundColor DarkGray
}

Write-Progress -Activity 'OpenFlux installer' -Completed
$total = [math]::Round(((Get-Date) - $ScriptStart).TotalSeconds, 1)
Write-Host ''
Write-Host "installed in ${total}s: " -ForegroundColor Green -NoNewline
Write-Host "$DestDir\$ExeName"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$DestDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$DestDir", 'User')
    $env:Path = "$env:Path;$DestDir"
    Warn "$DestDir added to your user PATH (restart the shell to pick it up)."
}

@"

Done. Examples:

  # client (SOCKS5 on 127.0.0.1:1080)
  $BinName --role=client --inbound=socks5 --transport=yandex --url="YOUR_DOC_URL"

  # exit node, no root needed
  $BinName --role=exit --mode=l4 --transport=yandex --url="YOUR_DOC_URL"

  # l3 on Windows goes through QEMU (see README TODO)

  $BinName -h
"@ | Write-Host
