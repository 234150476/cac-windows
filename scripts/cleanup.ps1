#!/usr/bin/env pwsh
# Claude Code Tracking Data Cleanup — Windows Version
# Based on: https://github.com/win4r/cc-notebook
$ErrorActionPreference = "Stop"

function Write-Title($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-OK($t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Skip($t) { Write-Host "  [SKIP] $t" -ForegroundColor Yellow }
function Write-Del($t) { Write-Host "  [DEL] $t" -ForegroundColor Red }

$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
$claudeDir = Join-Path $env:USERPROFILE ".claude"

# ── Menu ──
Write-Host ""
Write-Host "Claude Code Tracking Data Cleanup (Windows)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Reset Device Identity (userID/anonymousId)"
Write-Host "  2. Clear Telemetry & Analytics"
Write-Host "  3. Clear Sessions & History"
Write-Host "  4. Clear OAuth Account Linkage (need re-login)"
Write-Host "  5. Full Reset (nuclear — backup first)"
Write-Host "  6. All of the above (1-4, preserves config)"
Write-Host "  0. Exit"
Write-Host ""
$choice = Read-Host "Choose (0-6)"

# ── Level 1: Reset Device Identity ──
function Reset-DeviceIdentity {
    Write-Title "Level 1: Reset Device Identity"
    if (-not (Test-Path $claudeJson)) { Write-Skip ".claude.json not found"; return }

    $json = Get-Content $claudeJson -Raw | ConvertFrom-Json
    $keysToRemove = @("userID", "anonymousId", "firstStartTime", "claudeCodeFirstTokenDate")
    $removed = 0
    foreach ($k in $keysToRemove) {
        if ($json.PSObject.Properties[$k]) {
            $json.PSObject.Properties.Remove($k)
            Write-Del $k
            $removed++
        }
    }
    if ($removed -gt 0) {
        $json | ConvertTo-Json -Depth 10 | Set-Content $claudeJson -Encoding UTF8
        Write-OK "Device identity reset ($removed keys removed). New ID will be generated on next launch."
    } else {
        Write-Skip "No device identity keys found"
    }

    # Statsig stable ID
    $statsigDir = Join-Path $claudeDir "statsig"
    if (Test-Path $statsigDir) {
        Remove-Item $statsigDir -Recurse -Force
        Write-Del "statsig/ (stable ID)"
    }
}

# ── Level 2: Clear Telemetry & Analytics ──
function Clear-Telemetry {
    Write-Title "Level 2: Clear Telemetry & Analytics"
    $targets = @(
        @{ Path = "telemetry";        Desc = "unsent analytics events" },
        @{ Path = "statsig";          Desc = "feature flag cache + stable ID" },
        @{ Path = "stats-cache.json"; Desc = "statistics cache" }
    )
    foreach ($t in $targets) {
        $p = Join-Path $claudeDir $t.Path
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force
            Write-Del "$($t.Path) ($($t.Desc))"
        } else {
            Write-Skip "$($t.Path) not found"
        }
    }
}

# ── Level 3: Clear Sessions & History ──
function Clear-History {
    Write-Title "Level 3: Clear Sessions & History"
    $targets = @(
        @{ Path = "history.jsonl";   Desc = "command history" },
        @{ Path = "sessions";        Desc = "session snapshots" },
        @{ Path = "paste-cache";     Desc = "paste hash cache" },
        @{ Path = "shell-snapshots"; Desc = "shell environment snapshots" },
        @{ Path = "session-env";     Desc = "session environment variables" },
        @{ Path = "file-history";    Desc = "file edit records" },
        @{ Path = "debug";           Desc = "debug logs" },
        @{ Path = "projects";        Desc = "project sessions (resume data)" }
    )
    foreach ($t in $targets) {
        $p = Join-Path $claudeDir $t.Path
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force
            Write-Del "$($t.Path) ($($t.Desc))"
        } else {
            Write-Skip "$($t.Path) not found"
        }
    }
}

# ── Level 4: Clear OAuth Account Linkage ──
function Clear-OAuth {
    Write-Title "Level 4: Clear OAuth Account Linkage"

    # Remove credential from Windows Credential Manager
    try {
        $creds = cmdkey /list 2>&1 | Select-String "claude"
        if ($creds) {
            # Try known credential names
            foreach ($name in @("claude-code", "claude-code-credentials")) {
                cmdkey /delete:$name 2>&1 | Out-Null
            }
            Write-Del "Windows Credential Manager entries"
        } else {
            Write-Skip "No Claude credentials in Credential Manager"
        }
    } catch { Write-Skip "Credential Manager check failed" }

    # Remove OAuth keys from .claude.json
    if (Test-Path $claudeJson) {
        $json = Get-Content $claudeJson -Raw | ConvertFrom-Json
        $oauthKeys = @(
            "oauthAccount", "s1mAccessCache", "groveConfigCache",
            "passesEligibilityCache", "clientDataCache",
            "cachedExtraUsageDisabledReason", "githubRepoPaths",
            "hasExtraUsageEnabled"
        )
        $removed = 0
        foreach ($k in $oauthKeys) {
            if ($json.PSObject.Properties[$k]) {
                $json.PSObject.Properties.Remove($k)
                Write-Del $k
                $removed++
            }
        }
        if ($removed -gt 0) {
            $json | ConvertTo-Json -Depth 10 | Set-Content $claudeJson -Encoding UTF8
            Write-OK "OAuth linkage cleared ($removed keys). Need to re-login."
        } else {
            Write-Skip "No OAuth keys found"
        }
    }
}

# ── Level 5: Full Reset ──
function Full-Reset {
    Write-Title "Level 5: Full Reset (Nuclear)"
    Write-Host "  This will delete ALL Claude Code data." -ForegroundColor Red
    Write-Host "  Config, history, memory, skills, plugins — everything." -ForegroundColor Red
    $confirm = Read-Host "  Type 'YES' to confirm"
    if ($confirm -ne "YES") { Write-Skip "Cancelled"; return }

    # Backup config
    $backupDir = Join-Path $env:USERPROFILE "Desktop\claude-backup"
    if (-not (Test-Path $backupDir)) { New-Item $backupDir -ItemType Directory | Out-Null }

    $backupItems = @("settings.json", "settings.local.json", "skills", "hooks", "mcp-servers")
    foreach ($item in $backupItems) {
        $src = Join-Path $claudeDir $item
        if (Test-Path $src) {
            $dst = Join-Path $backupDir $item
            Copy-Item $src $dst -Recurse -Force
            Write-OK "Backed up $item"
        }
    }
    # Backup CLAUDE.md from current directory
    if (Test-Path "CLAUDE.md") {
        Copy-Item "CLAUDE.md" (Join-Path $backupDir "CLAUDE.md") -Force
        Write-OK "Backed up CLAUDE.md"
    }

    Write-Host "  Backup saved to: $backupDir" -ForegroundColor Green

    # Delete everything
    if (Test-Path $claudeDir) {
        Remove-Item $claudeDir -Recurse -Force
        Write-Del ".claude/ directory"
    }
    if (Test-Path $claudeJson) {
        Remove-Item $claudeJson -Force
        Write-Del ".claude.json"
    }

    # Clear credentials
    try {
        foreach ($name in @("claude-code", "claude-code-credentials")) {
            cmdkey /delete:$name 2>&1 | Out-Null
        }
    } catch {}

    Write-OK "Full reset complete. Run 'claude' to start fresh."
}

# ── Execute ──
switch ($choice) {
    "1" { Reset-DeviceIdentity }
    "2" { Clear-Telemetry }
    "3" { Clear-History }
    "4" { Clear-OAuth }
    "5" { Full-Reset }
    "6" {
        Reset-DeviceIdentity
        Clear-Telemetry
        Clear-History
        Clear-OAuth
        Write-Host "`nDone. Config preserved, tracking data cleared." -ForegroundColor Green
    }
    "0" { Write-Host "Bye." }
    default { Write-Host "Invalid choice" -ForegroundColor Red }
}
Write-Host ""
