#!/usr/bin/env pwsh
# Claude Code Tracking Data Cleanup — Windows
# Clears all tracking data while preserving config (MCP, Skills, Settings, Hooks)
$ErrorActionPreference = "Stop"

function Write-OK($t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Skip($t) { Write-Host "  [SKIP] $t" -ForegroundColor Yellow }
function Write-Del($t) { Write-Host "  [DEL] $t" -ForegroundColor Red }

$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
$claudeDir = Join-Path $env:USERPROFILE ".claude"

Write-Host ""
Write-Host "Claude Code Cleanup — clearing tracking data (config preserved)" -ForegroundColor Cyan
Write-Host ""

# ── 1. Reset Device Identity ──
Write-Host "Resetting device identity..." -ForegroundColor White
if (Test-Path $claudeJson) {
    $json = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable
    $removed = 0
    foreach ($k in @("userID", "anonymousId", "firstStartTime", "claudeCodeFirstTokenDate")) {
        if ($json.ContainsKey($k)) { $json.Remove($k); Write-Del $k; $removed++ }
    }
    if ($removed -gt 0) {
        $json | ConvertTo-Json -Depth 10 | Set-Content $claudeJson -Encoding UTF8
        Write-OK "Device identity reset ($removed keys)"
    } else { Write-Skip "No device identity keys" }
} else { Write-Skip ".claude.json not found" }

# ── 2. Clear Telemetry & Analytics ──
Write-Host "Clearing telemetry..." -ForegroundColor White
foreach ($t in @("telemetry", "statsig", "stats-cache.json")) {
    $p = Join-Path $claudeDir $t
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Del $t }
}

# ── 3. Clear Telemetry Cache Files ──
Write-Host "Clearing telemetry cache files..." -ForegroundColor White
foreach ($t in @("debug")) {
    $p = Join-Path $claudeDir $t
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Del $t }
}

# ── 4. Clear OAuth Account Linkage ──
Write-Host "Clearing OAuth linkage..." -ForegroundColor White
try {
    foreach ($name in @("claude-code", "claude-code-credentials")) {
        cmdkey /delete:$name 2>&1 | Out-Null
    }
    Write-Del "Credential Manager entries"
} catch { Write-Skip "Credential Manager" }

if (Test-Path $claudeJson) {
    $json = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable
    $removed = 0
    foreach ($k in @("oauthAccount", "s1mAccessCache", "groveConfigCache", "passesEligibilityCache", "clientDataCache", "cachedExtraUsageDisabledReason", "githubRepoPaths", "hasExtraUsageEnabled")) {
        if ($json.ContainsKey($k)) { $json.Remove($k); Write-Del $k; $removed++ }
    }
    if ($removed -gt 0) {
        $json | ConvertTo-Json -Depth 10 | Set-Content $claudeJson -Encoding UTF8
    }
}

Write-Host ""
Write-Host "Done. Tracking data cleared, config preserved." -ForegroundColor Green
Write-Host "Run 'claude login' to login with new account." -ForegroundColor White
Write-Host ""
