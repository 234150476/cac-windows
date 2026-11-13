const fs = require("fs");
const path = require("path");
const ccDir = process.argv[2] || path.join(process.env.APPDATA, "npm", "node_modules", "@anthropic-ai", "claude-code");

// Marker strings only exist in a patched binary (padding spaces never occur in minified source)
const TZ_MARKER = 'Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)   ';
const PRIVACY_MARKER = '=process.env.TZ||"UTC"   ';
const BOOT_MARKER = 'Date.prototype[m]=function(l,o){return f.call(this,l||"en",o)}';
const FUSE_MARKER = 'async function o(){return CAC_MID;';

// Same-length replacement: head + spaces + tail. Spaces are computed, never hand-typed.
// `at` is the 0-based occurrence of `orig` to target (default: first). Needed because the
// copyright comment we overwrite appears 2900 times in the binary.
function pad(orig, head, tail = "", at = null) {
  const n = orig.length - head.length - tail.length;
  if (n < 0) throw new Error("replacement longer than original: " + orig.slice(0, 30));
  const rep = head + " ".repeat(n) + tail;
  return at === null ? [orig, rep] : [orig, rep, at];
}

// Global prelude, injected into the two comment slots of the first code chunks. Each slot is
// 150 bytes, so the work is split in two: the TZ kick goes in chunk 1 (which runs first),
// the locale defaulting goes in chunk 2.
// 1) Re-assigning TZ makes JSC drop its cached timezone and re-read the env zone. Without it,
//    Windows ignores TZ entirely: Intl, getTimezoneOffset and Date getters all show Asia/Taipei.
//    With it, the whole process follows the chosen zone, not just the spots we patch by hand.
// 2) Locale cannot be set from LANG/LC_ALL on Windows (tested: stays zh-CN), so every
//    locale-less Date#toLocale*String would render Chinese dates ("2026年11月13日") into prompts.
const BOOT_TZ = pad(
  '// (c) Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance.',
  // TZ: re-assign so JSC resets its cached zone. CACHN/Z: fake hostname helpers (Z is the short
  // form used where the minified call site has no room to spare).
  'process.env.TZ=process.env.TZ;globalThis.Z=globalThis.CACHN=()=>process.env.CAC_HOSTNAME||"host";', '//', 0);

const BOOT_LOCALE = pad(
  '// (c) Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance.',
  'for(let k of["","Date","Time"]){let m="toLocale"+k+"String",f=Date.prototype[m];Date.prototype[m]=function(l,o){return f.call(this,l||"en",o)}}', '//', 1);

// Date#toString()/toTimeString() end with the zone name in the *system* locale:
//   "Thu Nov 12 2026 14:12:01 GMT-1000 (夏威夷阿留申标准时)"
// That is the last place Chinese text can appear from the machine's locale, so force the
// parenthesised zone name to English too. Split across the next two comment slots.
const BOOT_TZNAME = pad(
  '// (c) Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance.',
  'globalThis.CZ=(d)=>"("+Intl.DateTimeFormat("en",{timeZoneName:"long"}).formatToParts(d).find(p=>p.type==="timeZoneName").value+")";', '//', 2);

const BOOT_TOSTRING = pad(
  '// (c) Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance.',
  'for(let k of["","Time"]){let m="to"+k+"String",f=Date.prototype[m];Date.prototype[m]=function(){return f.call(this).replace(/\\([^)]*\\)$/,CZ(this))}}', '//', 3);

// The OpenTelemetry host detector is the only call site that sets host.name today. Bun's internal
// os module cannot be patched (the app holds its own copy of the module), so patch the call site.
const BOOT_HOST = [
  pad('[At.ATTR_HOST_NAME]:Cn.hostname()',
      '[At.ATTR_HOST_NAME]:CACHN()'),
];

// Fuse: machine id. getMachineId() shells out to REG.exe and reads HKLM\...\Cryptography\MachineGuid.
// Today nothing in the public build ships it, but a future release could. Short-circuit it to
// CAC_MACHINE_ID (set by the wrapper) so the real GUID can never leave the box. Returning
// undefined when the var is unset just drops the attribute — which is the outcome we want.
const fusePats = [
  // Dead code after `return` is legal, so only the first statement of getMachineId() changes.
  pad('let t="%windir%\\\\System32\\\\REG.exe";', 'return process.env.CAC_MACHINE_ID;'),
  // Remote Control bridge registration imports hostname straight from "os" as `Zo` and sends it
  // as machine_name. Hand-verified at 317 952 642 / 317 969 314 in 2.1.322.
  pad('gn=Zo(),', 'gn=Z(),'),
  pad('je=Zo(),', 'je=Z(),'),
];

// 2.1.322 signatures — minified names change every release, re-extract them from the new claude.exe
const tzPats = [
  pad('function uPs(){let e=new Date,t=wwo();if(t!==void 0){let o=new Map(XY("en-US",{timeZone:t,year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(e).map((s)=>[s.type,s.value]));return`${o.get("year")}-${o.get("month")}-${o.get("day")}`}let n=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),c=String(e.getDate()).padStart(2,"0");return`${n}-${r}-${c}`}',
      'function uPs(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)', '}'),
];

const privacyPats = [
  pad('function sca(){if(!g)g=Intl.DateTimeFormat().resolvedOptions().timeZone;return g}',
      'function sca(){if(!g)g=process.env.TZ||"UTC"', ';return g}'),
  pad('function ica(){if(l===null)try{let e=Intl.DateTimeFormat().resolvedOptions().locale;l=new Intl.Locale(e).language}catch{l=void 0}return l}',
      'function ica(){if(l===null)l="en";', 'return l}'),
  pad('let A=Intl.DateTimeFormat().resolvedOptions().timeZone',
      'let A=process.env.TZ||"UTC"'),
  ['.toLocaleDateString(void 0,{year:"numeric",month:"short",day:"numeric"})',
   '.toLocaleDateString( "en" ,{year:"numeric",month:"short",day:"numeric"})'],
  pad('Ie=-te.getTimezoneOffset(),Ue=Math.floor(Math.abs(Ie)/60),We=Math.abs(Ie)%60,Je=`${Ie>=0?"+":"-"}${String(Ue).padStart(2,"0")}:${String(We).padStart(2,"0")}`',
      'Ie=0', ',Ue=0,We=0,Je="+00:00"'),
  // auto-chart tool reads the zone directly
  pad('zone:Intl.DateTimeFormat().resolvedOptions().timeZone}',
      'zone:process.env.TZ||"UTC"', '}'),
  // per-turn "now" statement (server-gated, off today): its fallback sends the local UTC offset.
  // Route it through the TZ env zone instead; a failed explicit zone falls back to UTC, no recursion.
  pad('let r=(S)=>String(S).padStart(2,"0"),s=-e.getTimezoneOffset(),h=s<0?"-":"+",y=Math.abs(s);return`${e.getFullYear()}-${r(e.getMonth()+1)}-${r(e.getDate())}T${r(e.getHours())}:${r(e.getMinutes())}:${r(e.getSeconds())}${h}${r(Math.floor(y/60))}:${r(y%60)}`}',
      'return n?e.toISOString().slice(0,19)+"+00:00":tRn(e,process.env.TZ||"UTC")', '}'),
];

const binDir = path.join(ccDir, "bin");
const seaCandidates = ["claude.exe", "claude"].map(n => path.join(binDir, n)).filter(p => fs.existsSync(p));

if (seaCandidates.length === 0) {
  console.log("  No patchable binary found in " + binDir);
  process.exit(0);
}

function applyPats(bytes, text, pats) {
  let n = 0;
  for (const pat of pats) {
    const [o, r] = pat;
    // Third element = which occurrence of `o` to hit. Needed because the copyright comment we
    // overwrite appears 2900 times; 0 is a valid slot, so compare against undefined not falsy.
    const at = pat[2];
    if (o.length !== r.length) { console.log("  length mismatch, skipped: " + o.slice(0, 30)); continue; }
    const idx = at === undefined ? text.indexOf(o) : nthIndexOf(text, o, at);
    if (idx === -1) continue;
    Buffer.from(r, "latin1").copy(bytes, idx);
    n++;
  }
  return n;
}

function nthIndexOf(text, needle, n) {
  let idx = -1;
  for (let i = 0; i <= n; i++) {
    idx = text.indexOf(needle, idx + 1);
    if (idx === -1) return -1;
  }
  return idx;
}

let exitCode = 0;
for (const exe of seaCandidates) {
  const name = path.basename(exe);
  let bytes = fs.readFileSync(exe);
  let text = bytes.toString("latin1");
  const msgs = [];
  let changed = false;

  if (text.includes(BOOT_MARKER)) {
    msgs.push("Global boot patches already applied");
  } else {
    // Each prelude goes into its own 150-byte copyright comment line, taken in order (at: 0..3).
    const boot = [BOOT_TZ, BOOT_LOCALE, BOOT_TZNAME, BOOT_TOSTRING, ...BOOT_HOST];
    const n = applyPats(bytes, text, boot);
    if (n > 0) { changed = true; msgs.push("Global boot patches applied " + n + "/" + boot.length); }
    else msgs.push("Global boot patches skipped — signatures not found");
  }

  if (text.includes(FUSE_MARKER)) {
    msgs.push("Identity fuse already applied");
  } else {
    const n = applyPats(bytes, text, fusePats);
    if (n > 0) { changed = true; msgs.push("Identity fuse applied " + n + "/" + fusePats.length); }
    else msgs.push("Identity fuse skipped — signatures not found");
  }

  if (text.includes(TZ_MARKER)) {
    msgs.push("TZ patch already applied");
  } else {
    const n = applyPats(bytes, text, tzPats);
    if (n > 0) { changed = true; msgs.push("TZ patch applied"); }
    else msgs.push("TZ patch skipped — signature not found");
  }

  if (text.includes(PRIVACY_MARKER)) {
    msgs.push("Privacy patches already applied");
  } else {
    const n = applyPats(bytes, text, privacyPats);
    if (n > 0) { changed = true; msgs.push("Privacy patches applied " + n + "/" + privacyPats.length); }
    else msgs.push("Privacy patches skipped — signatures not found");
  }

  if (changed) {
    // Write FIRST, report after — a locked binary (claude running) must not be reported as patched.
    try {
      if (!fs.existsSync(exe + ".bak")) fs.copyFileSync(exe, exe + ".bak");
      fs.writeFileSync(exe, bytes);
    } catch (e) {
      exitCode = 1;
      if (e.code === "EBUSY" || e.code === "EPERM") {
        console.log("  PATCH FAILED (" + name + "): binary is locked — close all Claude Code sessions and retry");
      } else {
        console.log("  PATCH FAILED (" + name + "): " + e.message);
      }
      continue;
    }
  }
  msgs.forEach(m => console.log("  " + m + " (" + name + ")"));
}
process.exit(exitCode);
