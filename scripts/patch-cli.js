const fs = require("fs");
const path = require("path");
const ccDir = process.argv[2] || path.join(process.env.APPDATA, "npm", "node_modules", "@anthropic-ai", "claude-code");

// Marker strings only exist in a patched binary (padding spaces never occur in minified source)
const TZ_MARKER = 'Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)   ';
const PRIVACY_MARKER = '=process.env.TZ||"UTC"   ';

// 2.1.263 signatures — minified names change every release, re-extract with find-sigs.js
const tzPats = [
  ['function kSt(){let e=new Date,t=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),o=String(e.getDate()).padStart(2,"0");return`${t}-${r}-${o}`}',
   'function kSt(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                }'],
];

const privacyPats = [
  ['function sIn(){if(!u)u=Intl.DateTimeFormat().resolvedOptions().timeZone;return u}',
   'function sIn(){if(!u)u=process.env.TZ||"UTC"                           ;return u}'],
  ['function Wlr(){if(a===null)try{let e=Intl.DateTimeFormat().resolvedOptions().locale;a=new Intl.Locale(e).language}catch{a=void 0}return a}',
   'function Wlr(){if(a===null)a="en";                                                                                               return a}'],
  ['let _=Intl.DateTimeFormat().resolvedOptions().timeZone',
   'let _=process.env.TZ||"UTC"                           '],
  ['.toLocaleDateString(void 0,{year:"numeric",month:"short",day:"numeric"})',
   '.toLocaleDateString( "en" ,{year:"numeric",month:"short",day:"numeric"})'],
  ['Te=-fe.getTimezoneOffset(),xe=Math.floor(Math.abs(Te)/60),De=Math.abs(Te)%60,Ve=`${Te>=0?"+":"-"}${String(xe).padStart(2,"0")}:${String(De).padStart(2,"0")}`',
   'Te=0                                                                                                                                   ,xe=0,De=0,Ve="+00:00"'],
];

const binDir = path.join(ccDir, "bin");
const seaCandidates = ["claude.exe", "claude"].map(n => path.join(binDir, n)).filter(p => fs.existsSync(p));

if (seaCandidates.length === 0) {
  console.log("  No patchable binary found in " + binDir);
  process.exit(0);
}

function applyPats(bytes, text, pats) {
  let n = 0;
  for (const [o, r] of pats) {
    if (o.length !== r.length) { console.log("  length mismatch, skipped: " + o.slice(0, 30)); continue; }
    const idx = text.indexOf(o);
    if (idx === -1) continue;
    Buffer.from(r, "latin1").copy(bytes, idx);
    n++;
  }
  return n;
}

let exitCode = 0;
for (const exe of seaCandidates) {
  const name = path.basename(exe);
  let bytes = fs.readFileSync(exe);
  let text = bytes.toString("latin1");
  const msgs = [];
  let changed = false;

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
