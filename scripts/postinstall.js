#!/usr/bin/env node
var path = require('path');
var fs = require('fs');

var pkgDir = path.join(__dirname, '..');
var cacBin = path.join(pkgDir, 'cac');
var home = process.env.HOME || process.env.USERPROFILE || '';
var cacDir = path.join(home, '.cac');

// Ensure cac is executable
try { fs.chmodSync(cacBin, 0o755); } catch (e) {}

// Windows: override npm-generated shims (cac.cmd, cac.ps1) to use PowerShell version.
// npm auto-generates shims that call `bash cac`, but on Windows the system `bash`
// may point to WSL which can't resolve Windows paths. Our cac.ps1 is the native
// Windows entry point, so we make the shims call it directly.
if (process.platform === 'win32') {
  try {
    var npmBin = path.dirname(process.env.npm_node_execpath
      ? path.join(path.dirname(process.env.npm_node_execpath), '..', 'bin')
      : '');
    // Find the npm global bin dir by locating where our shim lives
    var shimCmd = path.join(pkgDir, '..', '..', 'cac.cmd');
    if (!fs.existsSync(shimCmd)) {
      // Fallback: npm prefix
      var spawnSync = require('child_process').spawnSync;
      var result = spawnSync('npm', ['prefix', '-g'], { encoding: 'utf8', shell: true });
      if (result.stdout) {
        shimCmd = path.join(result.stdout.trim(), 'cac.cmd');
      }
    }
    if (fs.existsSync(shimCmd)) {
      var shimDir = path.dirname(shimCmd);
      var cacPs1Src = path.join(pkgDir, 'cac.ps1');
      if (fs.existsSync(cacPs1Src)) {
        // cac.cmd → tries pwsh first, falls back to powershell.exe
        fs.writeFileSync(path.join(shimDir, 'cac.cmd'), [
          '@echo off',
          'where pwsh >nul 2>&1 && (',
          '    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0node_modules\\cac-windows\\cac.ps1" %*',
          '    exit /b %ERRORLEVEL%',
          ')',
          'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0node_modules\\cac-windows\\cac.ps1" %*',
          ''
        ].join('\r\n'));
        // cac.ps1 shim — tries pwsh first, falls back to powershell.exe
        fs.writeFileSync(path.join(shimDir, 'cac.ps1'), [
          '$cacDir = Join-Path (Split-Path $MyInvocation.MyCommand.Definition -Parent) "node_modules\\cac-windows"',
          '$ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }',
          '& $ps -NoProfile -ExecutionPolicy Bypass -File "$cacDir\\cac.ps1" @args',
          'exit $LASTEXITCODE',
          ''
        ].join('\r\n'));
      }
    }
  } catch (e) {
    // Non-fatal — user can manually run: pwsh cac.ps1
  }
}

// Auto-sync runtime files on install/upgrade
// Pure Node.js — no bash/zsh dependency
// Ensures bug fixes (dns-guard, relay, fingerprint-hook) take effect immediately
try {
  fs.mkdirSync(cacDir, { recursive: true });
  var files = ['cac-dns-guard.js', 'relay.js', 'fingerprint-hook.js'];
  for (var i = 0; i < files.length; i++) {
    var src = path.join(pkgDir, files[i]);
    var dst = path.join(cacDir, files[i]);
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, dst);
    }
  }
} catch (e) {
  // Non-fatal — _ensure_initialized will catch it on first cac command
}

// Patch existing wrapper for known bugs — pure Node.js, no shell execution needed.
// Users who upgrade via npm install keep their old ~/.cac/bin/claude until _ensure_initialized
// runs (triggered by any cac command). This patch fixes critical bugs immediately.
var wrapperPath = path.join(cacDir, 'bin', 'claude');
if (home && fs.existsSync(wrapperPath)) {
  try {
    var wrapperContent = fs.readFileSync(wrapperPath, 'utf8');
    var patched = wrapperContent;
    // Fix: pgrep returns exit 1 when no claude process exists; under set -euo pipefail
    // this aborts the wrapper before launching claude (claude appears to do nothing).
    var buggyPgrep = '_claude_count=$(pgrep -x "claude" 2>/dev/null | wc -l | tr -d \'[:space:]\')';
    var fixedPgrep = buggyPgrep + ' || _claude_count=0';
    if (patched.indexOf(buggyPgrep) !== -1 && patched.indexOf(fixedPgrep) === -1) {
      patched = patched.replace(buggyPgrep, fixedPgrep);
    }
    // Fix: session exit killed the shared relay, breaking all other sessions.
    // Remove the trap so _cleanup_all never fires on exit.
    var buggyTrap = 'trap _cleanup_all EXIT INT TERM';
    if (patched.indexOf(buggyTrap) !== -1) {
      patched = patched.replace(buggyTrap, '');
    }
    if (patched !== wrapperContent) {
      fs.writeFileSync(wrapperPath, patched);
    }
  } catch (e) {
    // Non-fatal
  }
}

// Migrate existing environments: generate missing files added in v1.5.0
// (fake_git_remote, git_email, device_token)
try {
  var crypto = require('crypto');
  var envsDir = path.join(cacDir, 'envs');
  if (fs.existsSync(envsDir)) {
    var envs = fs.readdirSync(envsDir);
    for (var ei = 0; ei < envs.length; ei++) {
      var envDir = path.join(envsDir, envs[ei]);
      if (!fs.statSync(envDir).isDirectory()) continue;
      // fake_git_remote
      if (!fs.existsSync(path.join(envDir, 'fake_git_remote'))) {
        var u1 = crypto.randomUUID().split('-')[0];
        var u2 = crypto.randomUUID().split('-')[1];
        fs.writeFileSync(path.join(envDir, 'fake_git_remote'), 'https://github.com/user-' + u1 + '/project-' + u2 + '.git\n');
      }
      // git_email
      if (!fs.existsSync(path.join(envDir, 'git_email'))) {
        var u3 = crypto.randomUUID().split('-')[0].toLowerCase();
        fs.writeFileSync(path.join(envDir, 'git_email'), 'user-' + u3 + '@users.noreply.github.com\n');
      }
      // device_token
      if (!fs.existsSync(path.join(envDir, 'device_token'))) {
        fs.writeFileSync(path.join(envDir, 'device_token'), crypto.randomBytes(32).toString('hex') + '\n');
      }
      // Migrate telemetry mode names
      var tmFile = path.join(envDir, 'telemetry_mode');
      if (fs.existsSync(tmFile)) {
        var tm = fs.readFileSync(tmFile, 'utf8').trim();
        var mapped = { conservative: 'stealth', aggressive: 'paranoid', off: 'transparent' };
        if (mapped[tm]) fs.writeFileSync(tmFile, mapped[tm] + '\n');
      }
    }
  }
} catch (e) {
  // Non-fatal — cac env create will generate these for new environments
}

// Trigger _ensure_initialized to fully regenerate wrapper to current version.
// cac env ls now calls _require_setup (fixed in 1.4.3+).
// Skip on Windows — the bash cac script can't run; user runs `cac setup` manually.
if (home && process.platform !== 'win32') {
  try {
    var spawnSync = require('child_process').spawnSync;
    spawnSync(cacBin, ['env', 'ls'], {
      stdio: 'ignore',
      timeout: 8000,
      env: Object.assign({}, process.env, { HOME: home })
    });
  } catch (e) {
    // Non-fatal
  }
}

// Ensure Claude Code's install.cjs has run (extracts the SEA binary).
// Newer npm versions block postinstall via allow-scripts, so claude.exe may not exist.
if (process.platform === 'win32') {
  try {
    var npmPrefix = process.env.npm_config_prefix || path.join(home, 'AppData', 'Roaming', 'npm');
    var ccBinDir = path.join(npmPrefix, 'node_modules', '@anthropic-ai', 'claude-code', 'bin');
    var ccInstall = path.join(npmPrefix, 'node_modules', '@anthropic-ai', 'claude-code', 'install.cjs');
    var hasExe = fs.existsSync(path.join(ccBinDir, 'claude.exe')) || fs.existsSync(path.join(ccBinDir, 'claude'));
    if (!hasExe && fs.existsSync(ccInstall)) {
      console.log('  Claude Code install.cjs not yet run (blocked by allow-scripts?) — running now...');
      require('child_process').spawnSync(process.execPath, [ccInstall], { stdio: 'inherit', timeout: 30000 });
    }
  } catch (e) { /* non-fatal */ }
}

// Patch claude.exe date function to respect TZ environment variable.
// Claude Code's SEA binary uses `new Date` which reads Windows system timezone,
// ignoring the TZ env var that cac sets per-environment. This patch replaces the
// date formatting function (byo) to use Intl.DateTimeFormat with process.env.TZ,
// so the system prompt "Today's date is YYYY-MM-DD" matches the proxy exit timezone.
// The replacement is byte-exact same length — no binary layout changes.
// IMPORTANT: This patch is verified against Claude Code 2.1.202. Other versions
// may have a different byo() signature and will be skipped with a warning.
var SUPPORTED_CLAUDE_VERSION = '2.1.202';
try {
  var claudeExePaths = [];
  // Check common install locations
  var npmPrefix = process.env.npm_config_prefix || path.join(home, 'AppData', 'Roaming', 'npm');
  var candidates = [
    path.join(npmPrefix, 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe'),
    path.join(npmPrefix, 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude'),
  ];
  for (var ci = 0; ci < candidates.length; ci++) {
    if (fs.existsSync(candidates[ci])) claudeExePaths.push(candidates[ci]);
  }

  var BYO_ORIGINAL = 'function byo(){let e=new Date,t=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),n=String(e.getDate()).padStart(2,"0");return`${t}-${r}-${n}`}';
  var BYO_PATCHED  = 'function byo(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                }';

  for (var pi = 0; pi < claudeExePaths.length; pi++) {
    var exePath = claudeExePaths[pi];
    var exeBytes = fs.readFileSync(exePath);
    var exeText = exeBytes.toString('latin1');

    // Already patched?
    if (exeText.indexOf(BYO_PATCHED) !== -1) continue;

    var byoIdx = exeText.indexOf(BYO_ORIGINAL);
    if (byoIdx === -1) {
      // Signature mismatch — warn user
      console.log('');
      console.log('  \x1b[33m⚠ TZ patch skipped\x1b[0m — claude binary signature mismatch.');
      console.log('  The TZ timezone patch is verified for Claude Code ' + SUPPORTED_CLAUDE_VERSION + '.');
      console.log('  To use TZ alignment, install the supported version:');
      console.log('    npm i -g @anthropic-ai/claude-code@' + SUPPORTED_CLAUDE_VERSION);
      console.log('');
      continue;
    }

    // Backup (only if no backup exists yet)
    var bakPath = exePath + '.bak';
    if (!fs.existsSync(bakPath)) {
      fs.copyFileSync(exePath, bakPath);
    }

    // Patch in place
    var patchBuf = Buffer.from(BYO_PATCHED, 'latin1');
    patchBuf.copy(exeBytes, byoIdx);
    fs.writeFileSync(exePath, exeBytes);
  }
} catch (e) {
  // Non-fatal — TZ patch is optional; cac works without it (system timezone is used)
}

var quickStart = [
  '',
  '  cac-windows installed successfully',
  ''
];
if (process.platform === 'win32') {
  quickStart.push(
    '  Quick start (Windows):',
    '    cac setup                             First-time setup',
    '    cac env create <name> [-p <proxy>]    Create an isolated environment',
    '    cac <name>                            Switch environment',
    '    claude                                Start Claude Code'
  );
} else {
  quickStart.push(
    '  Quick start:',
    '    cac env create <name> [-p <proxy>]   Create an isolated environment',
    '    cac <name>                           Switch environment',
    '    claude                               Start Claude Code'
  );
}
quickStart.push(
  '',
  '  Docs: https://cac.nextmind.space/docs',
  ''
);
console.log(quickStart.join('\n'));
