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

function Log($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "xx  $m" -ForegroundColor Red; exit 1 }

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

# ------------------------------------------------------------------ source ---
$here = (Get-Location).Path
if ((Test-Path (Join-Path $here 'go.mod')) -and
    ((Get-Content (Join-Path $here 'go.mod') -TotalCount 1) -match '^module openflux')) {
    $SrcDir = $here
    Log "building current checkout: $SrcDir"
}
elseif (Test-Path (Join-Path $SrcDir '.git')) {
    Log "updating $SrcDir"
    git -C $SrcDir fetch --depth 1 origin $Ref
    git -C $SrcDir checkout -q FETCH_HEAD
}
else {
    Log "cloning $Repo ($Ref) -> $SrcDir"
    New-Item -ItemType Directory -Force -Path (Split-Path $SrcDir) | Out-Null
    git clone --depth 1 --branch $Ref $Repo $SrcDir
}

# ------------------------------------------------------------------- build ---
$Go = Get-Go
Push-Location $SrcDir
try {
    Log 'resolving dependencies'
    & $Go mod download

    Log 'building'
    $env:CGO_ENABLED = '0'
    & $Go build -trimpath -ldflags '-s -w' -o $ExeName .
    if ($LASTEXITCODE -ne 0) { Die 'build failed' }
    if (-not (Test-Path (Join-Path $SrcDir $ExeName))) { Die 'build produced no binary' }
}
finally { Pop-Location }

# ----------------------------------------------------------------- install ---
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Copy-Item (Join-Path $SrcDir $ExeName) (Join-Path $DestDir $ExeName) -Force
Log "installed: $DestDir\$ExeName"

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
