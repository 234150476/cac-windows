#Requires -Version 5.1
<#
.SYNOPSIS
    cac -- Claude Anti-fingerprint Cloak (Windows)
.DESCRIPTION
    Windows management tool, equivalent to the Unix cac Bash script.
    Manages proxy environments, identity isolation, wrapper interception.
.EXAMPLE
    .\cac.ps1 setup
    .\cac.ps1 add us1 http://user:pass@host:port
    .\cac.ps1 us1
#>

$ErrorActionPreference = "Stop"

$CAC_DIR = Join-Path $env:USERPROFILE ".cac"
$ENVS_DIR = Join-Path $CAC_DIR "envs"

# ── helpers ───────────────────────────────────────────────

function Write-Green  { param($Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Red    { param($Msg) Write-Host $Msg -ForegroundColor Red }
function Write-Yellow { param($Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Bold   { param($Msg) Write-Host $Msg -ForegroundColor White }

function Read-FileValue {
    param([string]$Path, [string]$Default = "")
    if (Test-Path $Path) {
        return (Get-Content $Path -Raw).Trim()
    }
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

function Get-ProxyHostPort {
    param([string]$ProxyUrl)
    $hp = $ProxyUrl -replace ".*@", "" -replace ".*://", ""
    return $hp
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
    $hp = Get-ProxyHostPort $ProxyUrl
    $parts = $hp -split ":"
    if ($parts.Count -lt 2) { return $false }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($parts[0], [int]$parts[1], $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne(5000)
        $tcp.Close()
        return $success
    } catch { return $false }
}

function Require-Setup {
    $realClaude = Join-Path $CAC_DIR "real_claude"
    if (-not (Test-Path $realClaude)) {
        Write-Red "Error: run 'cac setup' first"
        exit 1
    }
}

function Get-CurrentEnv {
    return Read-FileValue (Join-Path $CAC_DIR "current")
}

function Find-RealClaude {
    $paths = $env:PATH -split ";" | Where-Object { $_ -notlike "*\.cac\bin*" }
    # Check for claude.exe first, then extensionless claude (SEA binary)
    foreach ($name in @("claude.exe", "claude")) {
        foreach ($p in $paths) {
            $candidate = Join-Path $p $name
            if (Test-Path $candidate) {
                # Skip shim scripts (.cmd/.ps1) — we need the real binary
                if ($candidate -match '\.(cmd|ps1|sh)$') { continue }
                return $candidate
            }
        }
    }
    # Fallback: check known npm install location directly
    $npmBin = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin"
    foreach ($name in @("claude.exe", "claude")) {
        $candidate = Join-Path $npmBin $name
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Update-Statsig {
    param([string]$StableId)
    $statsigDir = Join-Path $env:USERPROFILE ".claude\statsig"
    if (-not (Test-Path $statsigDir)) { return }
    Get-ChildItem (Join-Path $statsigDir "statsig.stable_id.*") -ErrorAction SilentlyContinue | ForEach-Object {
        Set-Content $_.FullName "`"$StableId`""
    }
}

function Update-ClaudeJsonUserId {
    param([string]$UserId)
    $jsonPath = Join-Path $env:USERPROFILE ".claude.json"
    if (-not (Test-Path $jsonPath)) { return }
    try {
        $d = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $d.userID = $UserId
        $d | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding UTF8
    } catch {
        Write-Yellow "Warning: failed to update ~/.claude.json userID"
    }
}

# ── write wrapper (claude.cmd) ────────────────────────────

function Write-Wrapper {
    $binDir = Join-Path $CAC_DIR "bin"
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null

    $wrapperContent = @'
@echo off
setlocal enabledelayedexpansion

set "CAC_DIR=%USERPROFILE%\.cac"
set "ENVS_DIR=!CAC_DIR!\envs"

REM stopped: passthrough
if exist "!CAC_DIR!\stopped" (
    for /f "usebackq delims=" %%i in ("!CAC_DIR!\real_claude") do set "REAL_CLAUDE=%%i"
    "!REAL_CLAUDE!" %*
    exit /b !ERRORLEVEL!
)

REM read current env
if not exist "!CAC_DIR!\current" (
    echo [cac] Error: no active env, run 'cac ^<name^>' >&2
    exit /b 1
)
for /f "usebackq delims=" %%i in ("!CAC_DIR!\current") do set "ENV_NAME=%%i"
set "ENV_DIR=!ENVS_DIR!\!ENV_NAME!"

if not exist "!ENV_DIR!" (
    echo [cac] Error: env '!ENV_NAME!' not found >&2
    exit /b 1
)

REM read proxy (optional — may not exist if no proxy configured)
set "PROXY="
if exist "!ENV_DIR!\proxy" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\proxy") do set "PROXY=%%i"
)

REM inject proxy
set "HTTPS_PROXY=!PROXY!"
set "HTTP_PROXY=!PROXY!"
set "ALL_PROXY=!PROXY!"
set "NO_PROXY=localhost,127.0.0.1"

REM telemetry kill switches
set "CLAUDE_CODE_SKIP_AUTO_UPDATE=1"
set "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
set "CLAUDE_CODE_ENABLE_TELEMETRY="
set "DO_NOT_TRACK=1"
set "OTEL_SDK_DISABLED=true"
set "OTEL_TRACES_EXPORTER=none"
set "OTEL_METRICS_EXPORTER=none"
set "OTEL_LOGS_EXPORTER=none"
set "SENTRY_DSN="
set "DISABLE_ERROR_REPORTING=1"
set "DISABLE_BUG_COMMAND=1"
set "TELEMETRY_DISABLED=1"
set "DISABLE_TELEMETRY=1"

REM clear third-party API config
set "ANTHROPIC_BASE_URL="
set "ANTHROPIC_AUTH_TOKEN="
set "ANTHROPIC_API_KEY="

REM fingerprint hook via NODE_OPTIONS
if exist "!ENV_DIR!\hostname" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\hostname") do set "CAC_HOSTNAME=%%i"
)
if exist "!ENV_DIR!\mac_address" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\mac_address") do set "CAC_MAC=%%i"
)
if exist "!ENV_DIR!\machine_id" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\machine_id") do set "CAC_MACHINE_ID=%%i"
)
set "CAC_USERNAME=user-!ENV_NAME:~0,8!"
if exist "!CAC_DIR!\fingerprint-hook.js" (
    echo !NODE_OPTIONS! | findstr /C:"fingerprint-hook.js" >nul 2>&1 || set "NODE_OPTIONS=--require !CAC_DIR!\fingerprint-hook.js !NODE_OPTIONS!"
)

REM timezone
if exist "!ENV_DIR!\tz" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\tz") do set "TZ=%%i"
)

REM locale
set "LANG=en_US.UTF-8"
if exist "!ENV_DIR!\lang" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\lang") do set "LANG=%%i"
)

REM inject statsig stable_id
if exist "!ENV_DIR!\stable_id" (
    for /f "usebackq delims=" %%i in ("!ENV_DIR!\stable_id") do set "STABLE_ID=%%i"
    for %%f in ("%USERPROFILE%\.claude\statsig\statsig.stable_id.*") do (
        if exist "%%f" echo "!STABLE_ID!"> "%%f"
    )
)

REM launch real claude
for /f "usebackq delims=" %%i in ("!CAC_DIR!\real_claude") do set "REAL_CLAUDE=%%i"
if not exist "!REAL_CLAUDE!" (
    echo [cac] Error: !REAL_CLAUDE! not found, run 'cac setup' >&2
    exit /b 1
)

"!REAL_CLAUDE!" %*
exit /b !ERRORLEVEL!
'@

    $wrapperPath = Join-Path $binDir "claude.cmd"
    Set-Content $wrapperPath $wrapperContent -Encoding ASCII
    Write-Host "  wrapper -> $wrapperPath"

    # PowerShell wrapper: ensures `claude` in pwsh also goes through cac
    # (PowerShell prioritizes .ps1 over .cmd, so without this the npm-generated
    # claude.ps1 would bypass cac entirely)
    # This is also the PRIMARY wrapper on Windows — it sets env vars directly in
    # the PowerShell process, which guarantees child processes inherit them.
    # The .cmd wrapper is kept as a fallback for cmd.exe users.
    $ps1Content = @'
#!/usr/bin/env pwsh
$ErrorActionPreference = "SilentlyContinue"
$CAC_DIR = Join-Path $env:USERPROFILE ".cac"
$ENVS_DIR = Join-Path $CAC_DIR "envs"

# stopped: passthrough
if (Test-Path (Join-Path $CAC_DIR "stopped")) {
    $real = (Get-Content (Join-Path $CAC_DIR "real_claude") -Raw).Trim()
    & $real @args; exit $LASTEXITCODE
}

# read current env
$currentFile = Join-Path $CAC_DIR "current"
if (-not (Test-Path $currentFile)) { Write-Error "[cac] no active env"; exit 1 }
$envName = (Get-Content $currentFile -Raw).Trim()
$envDir = Join-Path $ENVS_DIR $envName
if (-not (Test-Path $envDir)) { Write-Error "[cac] env '$envName' not found"; exit 1 }

function Read-Cac { param($f,$d="") $p=Join-Path $envDir $f; if(Test-Path $p){return(Get-Content $p -Raw).Trim()}; return $d }

# proxy (optional)
$proxy = Read-Cac "proxy"
if ($proxy) {
    $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy
    $env:ALL_PROXY = $proxy; $env:NO_PROXY = "localhost,127.0.0.1"
}

# telemetry
$tm = Read-Cac "telemetry_mode" "stealth"
if ($tm -eq "stealth") {
    $env:DISABLE_TELEMETRY = "1"
    $env:CLAUDE_CODE_ENHANCED_TELEMETRY_BETA = ""
}
if ($tm -eq "paranoid") {
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
    $env:DO_NOT_TRACK = "1"; $env:OTEL_SDK_DISABLED = "true"
    $env:OTEL_TRACES_EXPORTER = "none"; $env:OTEL_METRICS_EXPORTER = "none"
    $env:OTEL_LOGS_EXPORTER = "none"; $env:SENTRY_DSN = ""
    $env:DISABLE_ERROR_REPORTING = "1"; $env:DISABLE_BUG_COMMAND = "1"
    $env:TELEMETRY_DISABLED = "1"; $env:DISABLE_TELEMETRY = "1"
    $env:CLAUDE_CODE_ENHANCED_TELEMETRY_BETA = ""
}
$env:CLAUDE_CODE_ATTRIBUTION_HEADER = "0"

# clear API config when proxy is set
if ($proxy) {
    Remove-Item env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
}

# identity spoofing
$h = Read-Cac "hostname"; if($h){ $env:HOSTNAME=$h; $env:CAC_HOSTNAME=$h }
$m = Read-Cac "mac_address"; if($m){ $env:CAC_MAC=$m }
$mid = Read-Cac "machine_id"; if($mid){ $env:CAC_MACHINE_ID=$mid }
$env:CAC_USERNAME = "user-$($envName.Substring(0,[Math]::Min(8,$envName.Length)))"
$env:USER = $env:CAC_USERNAME; $env:LOGNAME = $env:CAC_USERNAME

# git spoofing
$ge = Read-Cac "git_email"; if($ge){ $env:CAC_GIT_EMAIL=$ge }
$gr = Read-Cac "fake_git_remote"; if($gr){ $env:CAC_FAKE_GIT_REMOTE=$gr }

# timezone & locale — set directly so child processes inherit
$tz = Read-Cac "tz"; if($tz){ $env:TZ=$tz }
$lang = Read-Cac "lang" "en_US.UTF-8"; $env:LANG=$lang

# fingerprint hook
$hookPath = Join-Path $CAC_DIR "fingerprint-hook.js"
if (Test-Path $hookPath) {
    if ($env:NODE_OPTIONS -notlike "*fingerprint-hook.js*") {
        $env:NODE_OPTIONS = "--require $hookPath $env:NODE_OPTIONS"
    }
}

# DNS guard
$dnsPath = Join-Path $CAC_DIR "cac-dns-guard.js"
if (Test-Path $dnsPath) {
    if ($env:NODE_OPTIONS -notlike "*cac-dns-guard.js*") {
        $env:NODE_OPTIONS = "$env:NODE_OPTIONS --require $dnsPath"
    }
}

# shim bin
$env:PATH = (Join-Path $CAC_DIR "shim-bin") + ";" + $env:PATH

# resolve real claude
$real = ""
$verFile = Join-Path $envDir "version"
if (Test-Path $verFile) {
    $ver = (Get-Content $verFile -Raw).Trim()
    $verBin = Join-Path $CAC_DIR "versions\$ver\claude"
    if (Test-Path $verBin) { $real = $verBin }
}
if (-not $real -or -not (Test-Path $real)) {
    $real = (Get-Content (Join-Path $CAC_DIR "real_claude") -Raw).Trim()
}
if (-not (Test-Path $real)) { Write-Error "[cac] claude not found"; exit 1 }

& $real @args
exit $LASTEXITCODE
'@
    $ps1Path = Join-Path $binDir "claude.ps1"
    Set-Content $ps1Path $ps1Content -Encoding UTF8
    Write-Host "  wrapper -> $ps1Path"
}

# ── cmd: setup ────────────────────────────────────────────

function Cmd-Setup {
    Write-Host "=== cac setup ==="

    $realClaude = Find-RealClaude
    if (-not $realClaude) {
        Write-Red "Error: claude.exe not found, install Claude Code first"
        Write-Host "  npm install -g @anthropic-ai/claude-code"
        exit 1
    }
    Write-Host "  real claude: $realClaude"

    New-Item -ItemType Directory -Path $ENVS_DIR -Force | Out-Null
    Set-Content (Join-Path $CAC_DIR "real_claude") $realClaude

    Write-Wrapper

    # copy fingerprint-hook.js
    $hookSrc = Join-Path $PSScriptRoot "fingerprint-hook.js"
    $hookDst = Join-Path $CAC_DIR "fingerprint-hook.js"
    if (Test-Path $hookSrc) {
        Copy-Item $hookSrc $hookDst -Force
        Write-Host "  fingerprint hook -> $hookDst"
    } elseif (Test-Path $hookDst) {
        Write-Host "  fingerprint hook (exists)"
    } else {
        Write-Yellow "  fingerprint-hook.js not found"
    }

    Write-Host ""
    Write-Host "-- Next steps --"
    Write-Host "1. Make sure PATH includes:"
    Write-Host ""
    Write-Host "   $CAC_DIR\bin       (claude wrapper)"
    Write-Host "   $env:USERPROFILE\bin     (cac command)"
    Write-Host ""
    Write-Host "2. Add your first environment:"
    Write-Host "   cac add <name> <host:port:user:pass>"
}

# ── cmd: add ──────────────────────────────────────────────

function Cmd-Add {
    param([string]$Name, [string]$RawProxy)
    Require-Setup

    if (-not $Name -or -not $RawProxy) {
        Write-Host "Usage: cac add <name> <host:port:user:pass>"
        Write-Host "  or:  cac add <name> http://user:pass@host:port"
        exit 1
    }

    $envDir = Join-Path $ENVS_DIR $Name
    if (Test-Path $envDir) {
        Write-Red "Error: env '$Name' already exists, use 'cac ls'"
        exit 1
    }

    $proxy = Parse-Proxy $RawProxy
    if (-not $proxy) {
        Write-Red "Error: invalid proxy format"
        exit 1
    }

    Write-Bold "Creating env: $Name"
    Write-Host "  Proxy: $proxy"
    Write-Host ""

    Write-Host -NoNewline "  Testing proxy ... "
    if (Test-ProxyReachable $proxy) {
        Write-Green "reachable"
    } else {
        Write-Yellow "unreachable"
        Write-Host "  Warning: proxy currently unreachable"
    }

    # detect timezone
    Write-Host -NoNewline "  Detecting timezone ... "
    $tz = "America/New_York"
    $lang = "en_US.UTF-8"
    try {
        $exitIp = & curl.exe -s --proxy $proxy --connect-timeout 8 https://api.ipify.org 2>$null
        if ($exitIp) {
            $ipInfo = & curl.exe -s --connect-timeout 8 "http://ip-api.com/json/${exitIp}?fields=timezone,countryCode" 2>$null
            $ipObj = $ipInfo | ConvertFrom-Json
            $tzResult = $ipObj.timezone
            if ($tzResult) { $tz = $tzResult }
        }
        Write-Green $tz
    } catch {
        Write-Yellow "failed, using default $tz"
    }
    Write-Host ""

    $confirm = Read-Host "Confirm? [yes/N]"
    if ($confirm -ne "yes") { Write-Host "Cancelled."; return }

    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    Set-Content (Join-Path $envDir "proxy")      $proxy
    Set-Content (Join-Path $envDir "uuid")        (New-Uuid)
    Set-Content (Join-Path $envDir "stable_id")   (New-Sid)
    Set-Content (Join-Path $envDir "user_id")     (New-UserId)
    Set-Content (Join-Path $envDir "machine_id")  (New-MachineId)
    Set-Content (Join-Path $envDir "hostname")    (New-FakeHostname)
    Set-Content (Join-Path $envDir "mac_address") (New-FakeMac)
    Set-Content (Join-Path $envDir "tz")          $tz
    Set-Content (Join-Path $envDir "lang")        $lang

    Write-Host ""
    Write-Green "Env '$Name' created"
    Write-Host "  UUID     : $(Get-Content (Join-Path $envDir 'uuid'))"
    Write-Host "  stable_id: $(Get-Content (Join-Path $envDir 'stable_id'))"
    Write-Host "  TZ       : $tz"
    Write-Host ""
    Write-Host "Switch to it: cac $Name"
}

# ── cmd: switch ───────────────────────────────────────────

function Cmd-Switch {
    param([string]$Name)
    Require-Setup

    $envDir = Join-Path $ENVS_DIR $Name
    if (-not (Test-Path $envDir)) {
        Write-Red "Error: env '$Name' not found, use 'cac ls'"
        exit 1
    }

    $proxy = Read-FileValue (Join-Path $envDir "proxy")
    Write-Host -NoNewline "Testing [$Name] proxy ... "
    if (Test-ProxyReachable $proxy) {
        Write-Green "reachable"
    } else {
        Write-Yellow "unreachable"
    }

    Set-Content (Join-Path $CAC_DIR "current") $Name
    $stoppedFile = Join-Path $CAC_DIR "stopped"
    if (Test-Path $stoppedFile) { Remove-Item $stoppedFile -Force }

    $stableId = Read-FileValue (Join-Path $envDir "stable_id")
    $userId = Read-FileValue (Join-Path $envDir "user_id")
    if ($stableId) { Update-Statsig $stableId }
    if ($userId) { Update-ClaudeJsonUserId $userId }

    Write-Green "Switched to $Name"
}

# ── cmd: ls ───────────────────────────────────────────────

function Cmd-Ls {
    Require-Setup

    if (-not (Test-Path $ENVS_DIR) -or (Get-ChildItem $ENVS_DIR -Directory -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Host "(no envs yet, use 'cac add <name> <proxy>')"
        return
    }

    $current = Get-CurrentEnv
    $stoppedTag = ""
    if (Test-Path (Join-Path $CAC_DIR "stopped")) { $stoppedTag = " [stopped]" }

    Get-ChildItem $ENVS_DIR -Directory | ForEach-Object {
        $name = $_.Name
        $proxy = Read-FileValue (Join-Path $_.FullName "proxy")
        $hp = Get-ProxyHostPort $proxy
        if ($name -eq $current) {
            Write-Host -NoNewline "  > " -ForegroundColor Green
            Write-Bold "${name}${stoppedTag}"
            Write-Host "    proxy: $hp"
        } else {
            Write-Host "    $name"
            Write-Host "    proxy: $hp"
        }
    }
}

# ── cmd: env set ─────────────────────────────────────────

function Cmd-EnvSet {
    param([string[]]$SetArgs)
    Require-Setup

    $knownKeys = @("proxy", "telemetry", "persona", "tz", "lang")

    if ($SetArgs.Count -lt 1) {
        Write-Host ""
        Write-Bold "cac env set — modify environment configuration"
        Write-Host ""
        Write-Host "  set [name] proxy <url>                          Set proxy"
        Write-Host "  set [name] proxy --remove                       Remove proxy"
        Write-Host "  set [name] telemetry <stealth|paranoid|transparent>"
        Write-Host "  set [name] persona <macos-vscode|macos-cursor|macos-iterm|linux-desktop|--remove>"
        Write-Host "  set [name] tz <timezone>                        Timezone (e.g. Pacific/Honolulu)"
        Write-Host "  set [name] lang <locale>                        Locale (e.g. en_US.UTF-8)"
        Write-Host ""
        Write-Host "  If name is omitted, uses the current active environment."
        Write-Host ""
        return
    }

    # Is first arg a known key or an env name?
    $name = ""
    $rest = $SetArgs
    if ($knownKeys -contains $SetArgs[0]) {
        $name = Get-CurrentEnv
        if (-not $name) { Write-Red "Error: no active environment — specify env name"; exit 1 }
    } else {
        $name = $SetArgs[0]
        if ($SetArgs.Count -gt 1) {
            $rest = $SetArgs[1..($SetArgs.Count - 1)]
        } else {
            $rest = @()
        }
    }

    $envDir = Join-Path $ENVS_DIR $name
    if (-not (Test-Path $envDir)) {
        Write-Red "Error: env '$name' not found"
        exit 1
    }

    if ($rest.Count -lt 1) {
        Write-Red "Error: missing key — use proxy, telemetry, persona, tz, or lang"
        exit 1
    }

    $key = $rest[0]
    $value = if ($rest.Count -ge 2) { $rest[1] } else { "" }
    $remove = ($value -eq "--remove")

    switch ($key) {
        "proxy" {
            if ($remove) {
                $proxyFile = Join-Path $envDir "proxy"
                if (Test-Path $proxyFile) { Remove-Item $proxyFile -Force }
                Write-Green "Removed proxy from $name"
            } else {
                if (-not $value) { Write-Red "Usage: cac env set [name] proxy <url>"; exit 1 }
                $proxyUrl = Parse-Proxy $value
                if (-not $proxyUrl) { Write-Red "Error: invalid proxy format"; exit 1 }
                Set-Content (Join-Path $envDir "proxy") $proxyUrl
                Write-Green "Set proxy for $name -> $proxyUrl"
            }
        }
        "telemetry" {
            if ($remove) { Write-Red "Error: cannot remove telemetry mode"; exit 1 }
            if (-not $value) { Write-Red "Usage: cac env set [name] telemetry <stealth|paranoid|transparent>"; exit 1 }
            # Accept old names
            switch ($value) {
                "conservative" { $value = "stealth" }
                "aggressive"   { $value = "paranoid" }
                "off"          { $value = "transparent" }
            }
            if ($value -notin @("stealth", "paranoid", "transparent")) {
                Write-Red "Error: invalid telemetry mode '$value' (use stealth, paranoid, or transparent)"
                exit 1
            }
            Set-Content (Join-Path $envDir "telemetry_mode") $value
            Write-Green "Set telemetry for $name -> $value"
        }
        "persona" {
            if ($remove) {
                $personaFile = Join-Path $envDir "persona"
                if (Test-Path $personaFile) { Remove-Item $personaFile -Force }
                Write-Green "Removed persona from $name"
            } else {
                if (-not $value) { Write-Red "Usage: cac env set [name] persona <macos-vscode|macos-cursor|macos-iterm|linux-desktop>"; exit 1 }
                if ($value -notin @("macos-vscode", "macos-cursor", "macos-iterm", "linux-desktop")) {
                    Write-Red "Error: invalid persona '$value'"
                    exit 1
                }
                Set-Content (Join-Path $envDir "persona") $value
                Write-Green "Set persona for $name -> $value"
            }
        }
        "tz" {
            if ($remove) { Write-Red "Error: cannot remove timezone — set a new value instead"; exit 1 }
            if (-not $value) { Write-Red "Usage: cac env set [name] tz <timezone>`n  examples: Pacific/Honolulu, America/New_York, Asia/Tokyo"; exit 1 }
            Set-Content (Join-Path $envDir "tz") $value
            Write-Green "Set timezone for $name -> $value"
        }
        "lang" {
            if ($remove) { Write-Red "Error: cannot remove locale — set a new value instead"; exit 1 }
            if (-not $value) { Write-Red "Usage: cac env set [name] lang <locale>`n  examples: en_US.UTF-8, ja_JP.UTF-8, zh_TW.UTF-8"; exit 1 }
            Set-Content (Join-Path $envDir "lang") $value
            Write-Green "Set locale for $name -> $value"
        }
        default {
            Write-Red "Error: unknown key '$key' — use proxy, telemetry, persona, tz, or lang"
            exit 1
        }
    }
}

# ── cmd: env create ──────────────────────────────────────

function Cmd-EnvCreate {
    param([string[]]$CreateArgs)
    Require-Setup

    $name = ""
    $proxy = ""
    $idx = 0
    while ($idx -lt $CreateArgs.Count) {
        switch ($CreateArgs[$idx]) {
            { $_ -in "-p", "--proxy" } {
                if ($idx + 1 -ge $CreateArgs.Count) { Write-Red "Error: $_ requires a value"; exit 1 }
                $proxy = $CreateArgs[$idx + 1]; $idx += 2
            }
            default {
                if (-not $name) { $name = $CreateArgs[$idx]; $idx++ }
                else { Write-Red "Error: extra argument: $($CreateArgs[$idx])"; exit 1 }
            }
        }
    }

    if (-not $name) {
        Write-Host "Usage: cac env create <name> [-p <proxy>]"
        exit 1
    }
    if ($name -notmatch '^[a-zA-Z0-9_-]+$') {
        Write-Red "Error: invalid name '$name' (use alphanumeric, dash, underscore)"
        exit 1
    }

    $envDir = Join-Path $ENVS_DIR $name
    if (Test-Path $envDir) {
        Write-Red "Error: environment '$name' already exists"
        exit 1
    }

    # Parse proxy if provided
    $proxyUrl = ""
    if ($proxy) {
        $proxyUrl = Parse-Proxy $proxy
        if (-not $proxyUrl) { Write-Red "Error: invalid proxy format"; exit 1 }

        Write-Host -NoNewline "  Testing proxy ... "
        if (Test-ProxyReachable $proxyUrl) { Write-Green "reachable" }
        else { Write-Yellow "unreachable" }
    }

    # Geo-detect timezone via proxy, or use defaults
    $tz = "America/New_York"
    $lang = "en_US.UTF-8"
    if ($proxyUrl) {
        Write-Host -NoNewline "  Detecting timezone ... "
        try {
            $exitIp = & curl.exe -s --proxy $proxyUrl --connect-timeout 8 https://api.ipify.org 2>$null
            if ($exitIp) {
                $ipInfo = & curl.exe -s --connect-timeout 8 "http://ip-api.com/json/${exitIp}?fields=timezone,countryCode" 2>$null
                $ipObj = $ipInfo | ConvertFrom-Json
                if ($ipObj.timezone) { $tz = $ipObj.timezone }
            }
            Write-Green $tz
        } catch {
            Write-Yellow "failed, using default $tz"
        }
    }

    # Create environment
    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    if ($proxyUrl) { Set-Content (Join-Path $envDir "proxy") $proxyUrl }
    Set-Content (Join-Path $envDir "uuid")        (New-Uuid)
    Set-Content (Join-Path $envDir "stable_id")   (New-Sid)
    Set-Content (Join-Path $envDir "user_id")     (New-UserId)
    Set-Content (Join-Path $envDir "machine_id")  (New-MachineId)
    Set-Content (Join-Path $envDir "hostname")    (New-FakeHostname)
    Set-Content (Join-Path $envDir "mac_address") (New-FakeMac)
    Set-Content (Join-Path $envDir "tz")          $tz
    Set-Content (Join-Path $envDir "lang")        $lang
    Set-Content (Join-Path $envDir "telemetry_mode") "stealth"

    # Auto-activate
    Set-Content (Join-Path $CAC_DIR "current") $name
    $stoppedFile = Join-Path $CAC_DIR "stopped"
    if (Test-Path $stoppedFile) { Remove-Item $stoppedFile -Force }

    Write-Host ""
    Write-Green "Created environment '$name'"
    Write-Host ""
    if ($proxyUrl) { Write-Host "  + proxy      $proxyUrl" }
    Write-Host "  + hostname   $(Get-Content (Join-Path $envDir 'hostname'))"
    Write-Host "  + tz         $tz"
    Write-Host "  + lang       $lang"
    Write-Host "  + telemetry  stealth"
    Write-Host ""
    Write-Host "  Environment activated. Run 'claude' to start."
    Write-Host ""
}

# ── cmd: env rm ──────────────────────────────────────────

function Cmd-EnvRm {
    param([string]$Name)
    Require-Setup
    if (-not $Name) { Write-Red "Usage: cac env rm <name>"; exit 1 }

    $envDir = Join-Path $ENVS_DIR $Name
    if (-not (Test-Path $envDir)) { Write-Red "Error: env '$Name' not found"; exit 1 }

    $current = Get-CurrentEnv
    if ($Name -eq $current) { Write-Red "Error: cannot remove active environment '$Name' — switch to another first"; exit 1 }

    Remove-Item $envDir -Recurse -Force -Confirm:$false
    Write-Green "Removed environment '$Name'"
}

# ── cmd: env (router) ────────────────────────────────────

function Cmd-Env {
    param([string[]]$EnvArgs)

    if ($EnvArgs.Count -lt 1) {
        Write-Host ""
        Write-Bold "cac env — environment management"
        Write-Host ""
        Write-Host "  env create <name> [-p <proxy>]   Create isolated environment (auto-activates)"
        Write-Host "  env set [name] <key> <value>     Modify environment (proxy, telemetry, persona, tz, lang)"
        Write-Host "  env rm <name>                    Remove an environment"
        Write-Host "  env ls                           List all environments"
        Write-Host "  env check                        Verify current environment"
        Write-Host ""
        return
    }

    switch ($EnvArgs[0]) {
        "create" { if ($EnvArgs.Count -gt 1) { Cmd-EnvCreate $EnvArgs[1..($EnvArgs.Count - 1)] } else { Cmd-EnvCreate @() } }
        "set"    { if ($EnvArgs.Count -gt 1) { Cmd-EnvSet $EnvArgs[1..($EnvArgs.Count - 1)] } else { Cmd-EnvSet @() } }
        "rm"     { if ($EnvArgs.Count -gt 1) { Cmd-EnvRm $EnvArgs[1] } else { Write-Red "Usage: cac env rm <name>"; exit 1 } }
        "remove" { if ($EnvArgs.Count -gt 1) { Cmd-EnvRm $EnvArgs[1] } else { Write-Red "Usage: cac env rm <name>"; exit 1 } }
        "ls"     { Cmd-Ls }
        "list"   { Cmd-Ls }
        "check"  { Cmd-Check }
        "stop"   { Cmd-Stop }
        default  { Write-Red "Error: unknown subcommand 'env $($EnvArgs[0])'"; exit 1 }
    }
}

# ── cmd: check ────────────────────────────────────────────

function Cmd-Check {
    Require-Setup

    if (Test-Path (Join-Path $CAC_DIR "stopped")) {
        Write-Yellow "cac is stopped -- claude running without protection"
        Write-Host "  Resume: cac -c"
        return
    }

    $current = Get-CurrentEnv
    if (-not $current) {
        Write-Red "Error: no active env, run 'cac <name>'"
        exit 1
    }

    $envDir = Join-Path $ENVS_DIR $current
    $proxy = Read-FileValue (Join-Path $envDir "proxy")

    Write-Bold "Current env: $current"
    Write-Host "  Proxy     : $(Get-ProxyHostPort $proxy)"
    Write-Host "  UUID      : $(Read-FileValue (Join-Path $envDir 'uuid'))"
    Write-Host "  stable_id : $(Read-FileValue (Join-Path $envDir 'stable_id'))"
    Write-Host "  user_id   : $(Read-FileValue (Join-Path $envDir 'user_id'))"
    Write-Host "  TZ        : $(Read-FileValue (Join-Path $envDir 'tz') '(not set)')"
    Write-Host ""

    Write-Host -NoNewline "  TCP test  ... "
    if (-not (Test-ProxyReachable $proxy)) {
        Write-Red "FAIL"
        return
    }
    Write-Green "OK"

    Write-Host -NoNewline "  Exit IP   ... "
    try {
        $ip = & curl.exe -s --proxy $proxy --connect-timeout 8 https://api.ipify.org 2>$null
        if ($ip) { Write-Green $ip } else { Write-Yellow "failed" }
    } catch {
        Write-Yellow "failed"
    }
}

# ── cmd: stop / continue ─────────────────────────────────

function Cmd-Stop {
    New-Item -ItemType File -Path (Join-Path $CAC_DIR "stopped") -Force | Out-Null
    Write-Yellow "cac stopped -- claude will run without proxy/disguise"
    Write-Host "  Resume: cac -c"
}

function Cmd-Continue {
    $stoppedFile = Join-Path $CAC_DIR "stopped"
    if (-not (Test-Path $stoppedFile)) {
        Write-Host "cac is not stopped"
        return
    }

    $current = Get-CurrentEnv
    if (-not $current) {
        Write-Red "Error: no active env, run 'cac <name>'"
        exit 1
    }

    Remove-Item $stoppedFile -Force
    Write-Green "cac resumed -- current env: $current"
}

# ── cmd: help ─────────────────────────────────────────────

function Cmd-Help {
    Write-Host ""
    Write-Bold "cac -- Claude Anti-fingerprint Cloak (Windows)"
    Write-Host ""
    Write-Bold "Usage:"
    Write-Host "  cac setup                              First-time setup"
    Write-Host "  cac add <name> <host:port:user:pass>   Add new env"
    Write-Host "  cac <name>                             Switch to env"
    Write-Host "  cac ls                                 List all envs"
    Write-Host "  cac check                              Check current env"
    Write-Host "  cac env set [name] <key> <value>       Modify env config"
    Write-Host "  cac stop                               Temporarily disable"
    Write-Host "  cac -c                                 Resume from stop"
    Write-Host ""
    Write-Bold "Proxy formats:"
    Write-Host "  host:port:user:pass                    With auth"
    Write-Host "  host:port                              No auth"
    Write-Host "  http://user:pass@host:port             Full URL"
    Write-Host "  socks5://host:port                     SOCKS5"
    Write-Host ""
    Write-Bold "Examples:"
    Write-Host "  cac setup"
    Write-Host "  cac add us1 1.2.3.4:1080:username:password"
    Write-Host "  cac us1"
    Write-Host "  cac check"
    Write-Host ""
    Write-Bold "Files:"
    Write-Host "  %USERPROFILE%\.cac\bin\claude.cmd           Wrapper"
    Write-Host "  %USERPROFILE%\.cac\current                  Active env"
    Write-Host "  %USERPROFILE%\.cac\envs\<name>\             Env data"
    Write-Host "  %USERPROFILE%\.cac\fingerprint-hook.js      Node.js hook"
    Write-Host ""
}

# ── entry: dispatch ───────────────────────────────────────

if ($args.Count -eq 0) { Cmd-Help; exit 0 }

switch ($args[0]) {
    "setup"   { Cmd-Setup }
    "add"     { Cmd-Add $args[1] $args[2] }
    "env"     { if ($args.Count -gt 1) { Cmd-Env $args[1..($args.Count - 1)] } else { Cmd-Env @() } }
    "ls"      { Cmd-Ls }
    "list"    { Cmd-Ls }
    "check"   { Cmd-Check }
    "stop"    { Cmd-Stop }
    "-c"      { Cmd-Continue }
    "help"    { Cmd-Help }
    "--help"  { Cmd-Help }
    "-h"      { Cmd-Help }
    default   { Cmd-Switch $args[0] }
}
