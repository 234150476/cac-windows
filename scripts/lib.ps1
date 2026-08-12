# cac-windows — shared utility functions
$ErrorActionPreference = "Stop"

$CAC_DIR = Join-Path $env:USERPROFILE ".cac"
$ENVS_DIR = Join-Path $CAC_DIR "envs"

function Write-OK($t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Err($t) { Write-Host "  [!!] $t" -ForegroundColor Red }
function Write-Warn($t) { Write-Host "  [--] $t" -ForegroundColor Yellow }

function Read-FileValue {
    param([string]$Path, [string]$Default = "")
    if (Test-Path $Path) { return (Get-Content $Path -Raw).Trim() }
    return $Default
}

function New-Uuid    { return [guid]::NewGuid().ToString().ToUpper() }
function New-Sid     { return [guid]::NewGuid().ToString().ToLower() }
function New-UserId  { return -join ((1..32) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) }) }
function New-MachineId { return [guid]::NewGuid().ToString().Replace("-","").ToLower() }
function New-FakeHostname { return "host-$([guid]::NewGuid().ToString().Split('-')[0].ToLower())" }
function New-FakeMac {
    $bytes = @(0x02) + (1..5 | ForEach-Object { Get-Random -Maximum 256 })
    return ($bytes | ForEach-Object { "{0:x2}" -f $_ }) -join ":"
}

function Parse-Proxy {
    param([string]$Raw)
    if ($Raw -match "^(http|https|socks5)://") { return $Raw }
    $parts = $Raw -split ":"
    if ($parts.Count -ge 4) {
        return "http://$($parts[2]):$($parts[3])@$($parts[0]):$($parts[1])"
    } elseif ($parts.Count -ge 2) {
        return "http://$($parts[0]):$($parts[1])"
    }
    return $null
}

function Test-ProxyReachable {
    param([string]$ProxyUrl)
    $hp = ($ProxyUrl -replace ".*@", "" -replace ".*://", "") -split ":"
    if ($hp.Count -lt 2) { return $false }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($hp[0], [int]$hp[1], $null, $null)
        $ok = $result.AsyncWaitHandle.WaitOne(5000)
        $tcp.Close()
        return $ok
    } catch { return $false }
}

function Find-RealClaude {
    $npmBase = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code"
    foreach ($name in @("claude.exe", "claude")) {
        $c = Join-Path $npmBase "bin\$name"
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-CurrentEnv { return Read-FileValue (Join-Path $CAC_DIR "current") }

function Get-EnvDir {
    param([string]$Name)
    return Join-Path $ENVS_DIR $Name
}

function Update-Statsig {
    param([string]$StableId)
    $d = Join-Path $env:USERPROFILE ".claude\statsig"
    if (-not (Test-Path $d)) { return }
    Get-ChildItem (Join-Path $d "statsig.stable_id.*") -ErrorAction SilentlyContinue | ForEach-Object {
        Set-Content $_.FullName "`"$StableId`""
    }
}

function Update-ClaudeJsonUserId {
    param([string]$UserId)
    $p = Join-Path $env:USERPROFILE ".claude.json"
    if (-not (Test-Path $p)) { return }
    try {
        $d = Get-Content $p -Raw | ConvertFrom-Json
        $d.userID = $UserId
        $d | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8
    } catch {}
}

function Write-Wrapper {
    $binDir = Join-Path $CAC_DIR "bin"
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null

    # CMD wrapper
    $cmd = @'
@echo off
setlocal enabledelayedexpansion
set "CAC_DIR=%USERPROFILE%\.cac"
set "ENVS_DIR=!CAC_DIR!\envs"
if not exist "!CAC_DIR!\current" (
    echo [cac] no active env >&2 & exit /b 1
)
for /f "usebackq delims=" %%i in ("!CAC_DIR!\current") do set "ENV_NAME=%%i"
set "ENV_DIR=!ENVS_DIR!\!ENV_NAME!"
if exist "!ENV_DIR!\proxy" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\proxy") do set "PROXY=%%i"
    set "HTTPS_PROXY=!PROXY!" & set "HTTP_PROXY=!PROXY!"
    set "ALL_PROXY=!PROXY!" & set "NO_PROXY=localhost,127.0.0.1"
)
if exist "!ENV_DIR!\tz" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\tz") do set "TZ=%%i"
)
set "LANG=en_US.UTF-8"
if exist "!ENV_DIR!\lang" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\lang") do set "LANG=%%i"
)
if exist "!ENV_DIR!\stable_id" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\stable_id") do set "STABLE_ID=%%i"
    for %%f in ("%USERPROFILE%\.claude\statsig\statsig.stable_id.*") do (
        if exist "%%f" echo "!STABLE_ID!"> "%%f"
    )
)
for /f "usebackq delims=" %%i in ("!CAC_DIR!\real_claude") do set "REAL_CLAUDE=%%i"
"!REAL_CLAUDE!" %*
exit /b !ERRORLEVEL!
'@
    Set-Content (Join-Path $binDir "claude.cmd") $cmd -Encoding ASCII

    # PowerShell wrapper
    $ps1 = @'
$ErrorActionPreference = "SilentlyContinue"
$d = Join-Path $env:USERPROFILE ".cac"
$cf = Join-Path $d "current"
if (-not (Test-Path $cf)) { Write-Error "[cac] no active env"; exit 1 }
$en = (Get-Content $cf -Raw).Trim()
$ed = Join-Path $d "envs\$en"
$pf = Join-Path $ed "proxy"
if (Test-Path $pf) {
    $px = (Get-Content $pf -Raw).Trim()
    $env:HTTPS_PROXY=$px; $env:HTTP_PROXY=$px
    $env:ALL_PROXY=$px; $env:NO_PROXY="localhost,127.0.0.1"
}
$tf = Join-Path $ed "tz"
if (Test-Path $tf) { $env:TZ = (Get-Content $tf -Raw).Trim() }
$lf = Join-Path $ed "lang"
if (Test-Path $lf) { $env:LANG = (Get-Content $lf -Raw).Trim() } else { $env:LANG = "en_US.UTF-8" }
$sf = Join-Path $ed "stable_id"
if (Test-Path $sf) {
    $sid = (Get-Content $sf -Raw).Trim()
    $sd = Join-Path $env:USERPROFILE ".claude\statsig"
    if (Test-Path $sd) {
        Get-ChildItem (Join-Path $sd "statsig.stable_id.*") -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Content $_.FullName "`"$sid`""
        }
    }
}
$uf = Join-Path $ed "user_id"
if (Test-Path $uf) {
    $cj = Join-Path $env:USERPROFILE ".claude.json"
    if (Test-Path $cj) {
        try {
            $jd = Get-Content $cj -Raw | ConvertFrom-Json
            $jd.userID = (Get-Content $uf -Raw).Trim()
            $jd | ConvertTo-Json -Depth 10 | Set-Content $cj -Encoding UTF8
        } catch {}
    }
}
$real = (Get-Content (Join-Path $d "real_claude") -Raw).Trim()
if (-not (Test-Path $real)) { Write-Error "[cac] claude not found"; exit 1 }
& $real @args
exit $LASTEXITCODE
'@
    Set-Content (Join-Path $binDir "claude.ps1") $ps1 -Encoding UTF8
}
