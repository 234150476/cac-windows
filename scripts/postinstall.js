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
          'if (Get-Command pwsh -ErrorAction SilentlyContinue) { $ps = "pwsh" } else { $ps = "powershell.exe" }',
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

// ── Windows: ensure correct Claude Code version is installed and patched ──
// Handles three cases automatically:
//   1. Claude Code not installed → install pinned version
//   2. Claude Code wrong version → reinstall pinned version
//   3. install.cjs not run (allow-scripts blocked) → run it
//   4. TZ patch not applied → apply it
var SUPPORTED_CLAUDE_VERSION = '2.1.222';
var CC_PKG = '@anthropic-ai/claude-code';
if (process.platform === 'win32') {
  var spawnSync = require('child_process').spawnSync;
  var npmPrefix = process.env.npm_config_prefix || path.join(home, 'AppData', 'Roaming', 'npm');
  var ccDir = path.join(npmPrefix, 'node_modules', CC_PKG);
  var ccBinDir = path.join(ccDir, 'bin');
  var ccInstall = path.join(ccDir, 'install.cjs');
  var ccPkgJson = path.join(ccDir, 'package.json');

  // Step 1: Check if Claude Code is installed
  var needInstall = false;
  if (!fs.existsSync(ccPkgJson)) {
    console.log('  Claude Code not found — installing v' + SUPPORTED_CLAUDE_VERSION + '...');
    needInstall = true;
  } else {
    try {
      var ccVersion = JSON.parse(fs.readFileSync(ccPkgJson, 'utf8')).version;
      if (ccVersion !== SUPPORTED_CLAUDE_VERSION) {
        console.log('  Claude Code v' + ccVersion + ' detected (TZ patch supports v' + SUPPORTED_CLAUDE_VERSION + ').');
        console.log('  TZ patch will be skipped. Other cac features work normally.');
        console.log('  To get TZ support: npm i -g ' + CC_PKG + '@' + SUPPORTED_CLAUDE_VERSION);
      }
    } catch (e) { needInstall = true; }
  }

  if (needInstall) {
    var installResult = spawnSync('npm', ['install', '-g', CC_PKG + '@' + SUPPORTED_CLAUDE_VERSION,
      '--registry', 'https://registry.npmjs.org'], {
      encoding: 'utf8', shell: true, stdio: 'inherit', timeout: 120000
    });
    if (installResult.status !== 0) {
      console.log('  \x1b[33m⚠ Claude Code install failed\x1b[0m — install manually:');
      console.log('    npm i -g ' + CC_PKG + '@' + SUPPORTED_CLAUDE_VERSION);
    }
  }

  // Step 2: Ensure install.cjs has run (extracts the SEA binary)
  try {
    var hasExe = fs.existsSync(path.join(ccBinDir, 'claude.exe')) || fs.existsSync(path.join(ccBinDir, 'claude'));
    if (!hasExe && fs.existsSync(ccInstall)) {
      console.log('  Running Claude Code install.cjs (blocked by allow-scripts)...');
      spawnSync(process.execPath, [ccInstall], { stdio: 'inherit', timeout: 30000 });
    }
  } catch (e) { /* non-fatal */ }

  // Step 3: Apply TZ patch (SEA binary only)
  try {
    var DATE_PATTERNS = [
      { original: 'function fys(){let e=new Date,t=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),n=String(e.getDate()).padStart(2,"0");return`${t}-${r}-${n}`}',
        replacement: function() { return 'function fys(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)' + ' '.repeat(62) + '}'; } },
    ];
    var TZ_PATCHED_MARKER = 'Intl.DateTimeFormat("sv"';

    var seaCandidates = [path.join(ccBinDir, 'claude.exe'), path.join(ccBinDir, 'claude')];
    for (var ci = 0; ci < seaCandidates.length; ci++) {
      if (!fs.existsSync(seaCandidates[ci])) continue;
      var target = seaCandidates[ci];
      var content = fs.readFileSync(target).toString('latin1');

      if (content.indexOf(TZ_PATCHED_MARKER) !== -1) continue;

      var patched = false;
      for (var di = 0; di < DATE_PATTERNS.length; di++) {
        var pat = DATE_PATTERNS[di];
        var idx = content.indexOf(pat.original);
        if (idx === -1) continue;

        var bakPath = target + '.bak';
        if (!fs.existsSync(bakPath)) fs.copyFileSync(target, bakPath);

        var exeBytes = fs.readFileSync(target);
        var patchBuf = Buffer.from(pat.replacement(), 'latin1');
        patchBuf.copy(exeBytes, idx);
        fs.writeFileSync(target, exeBytes);
        console.log('  \x1b[32m✓ TZ patch applied\x1b[0m (' + path.basename(target) + ')');
        patched = true;
        break;
      }
      if (!patched) {
        console.log('  \x1b[33m⚠ TZ patch skipped\x1b[0m — date function signature not recognized in ' + path.basename(target));
      }
    }
  } catch (e) {
    // Non-fatal — TZ patch is optional; cac works without it
  }

  // Step 4: Privacy patches — fix timezone/locale/offset leaks (2.1.222)
  try {
    var PRIVACY_MARKER = 'mss=process.env.TZ';
    var PRIVACY_PATS = [
      ['function yss(){if(!mss)mss=Intl.DateTimeFormat().resolvedOptions().timeZone;return mss}',
       'function yss(){if(!mss)mss=process.env.TZ||"UTC"                           ;return mss}'],
      ['function Zsu(){if(rpo===null)try{let e=Intl.DateTimeFormat().resolvedOptions().locale;rpo=new Intl.Locale(e).language}catch{rpo=void 0}return rpo}',
       'function Zsu(){if(rpo===null)rpo="en";                                                                                                 return rpo}'],
      ['let l=Intl.DateTimeFormat().resolvedOptions().timeZone',
       'let l=process.env.TZ||"UTC"                           '],
      ['.toLocaleDateString(void 0,{year:"numeric",month:"short",day:"numeric"})',
       '.toLocaleDateString( "en" ,{year:"numeric",month:"short",day:"numeric"})'],
    ];
    var AKM_ORIG = 'i=-n.getTimezoneOffset(),s=Math.floor(Math.abs(i)/60),a=Math.abs(i)%60,c=`${i>=0?"+":"-"}${String(s).padStart(2,"0")}:${String(a).padStart(2,"0")}`';
    var AKM_REPL = 'i=0                                                                                                                             ,s=0,a=0,c="+00:00"';

    for (var ci = 0; ci < seaCandidates.length; ci++) {
      if (!fs.existsSync(seaCandidates[ci])) continue;
      var privExe = seaCandidates[ci];
      var privBytes = fs.readFileSync(privExe);
      var privText = privBytes.toString('latin1');
      if (privText.indexOf(PRIVACY_MARKER) !== -1) continue;
      var privChanged = false;
      for (var pp = 0; pp < PRIVACY_PATS.length; pp++) {
        var po = PRIVACY_PATS[pp][0], pr = PRIVACY_PATS[pp][1];
        var pidx = privText.indexOf(po);
        if (pidx === -1 || po.length !== pr.length) continue;
        Buffer.from(pr, 'latin1').copy(privBytes, pidx);
        privChanged = true;
      }
      var akmIdx = privText.indexOf(AKM_ORIG);
      if (akmIdx !== -1 && AKM_ORIG.length === AKM_REPL.length) {
        Buffer.from(AKM_REPL, 'latin1').copy(privBytes, akmIdx);
        privChanged = true;
      }
      if (privChanged) {
        if (!fs.existsSync(privExe + '.bak')) fs.copyFileSync(privExe, privExe + '.bak');
        fs.writeFileSync(privExe, privBytes);
        console.log('  \x1b[32m✓ Privacy patches applied\x1b[0m (' + path.basename(privExe) + ')');
      }
    }
  } catch (e) {
    // Non-fatal — privacy patches are optional
  }
}

var quickStart = [
  '',
  '  cac-windows installed successfully',
  ''
];
if (process.platform === 'win32') {
  quickStart.push(
    '  Quick start:',
    '    cac                                   Launch menu',
    '    claude                                Start Claude Code'
  );
} else {
  quickStart.push(
    '  Quick start:',
    '    cac                                   Launch menu',
    '    claude                                Start Claude Code'
  );
}
quickStart.push(
  '',
  '  Docs: https://cac.nextmind.space/docs',
  ''
);
console.log(quickStart.join('\n'));
