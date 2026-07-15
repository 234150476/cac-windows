const fs = require("fs");
const path = require("path");
const ccDir = process.argv[2] || path.join(process.env.APPDATA, "npm", "node_modules", "@anthropic-ai", "claude-code");

const TZ_MARKER = 'Intl.DateTimeFormat("sv"';
const tzPats = [
  ['function TD6(){let A=new Date,q=A.getFullYear(),K=String(A.getMonth()+1).padStart(2,"0"),Y=String(A.getDate()).padStart(2,"0");return`${q}-${K}-${Y}`}',
   'function TD6(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                 }'],
  ['function byo(){let e=new Date,t=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),n=String(e.getDate()).padStart(2,"0");return`${t}-${r}-${n}`}',
   'function byo(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                }'],
];
const SESSION_BUG = 'firstLine:K.split(`';
const SESSION_FIX = 'firstLine:(K||"").split(`';

// --- Patch cli.js (plain text, older versions like 2.1.77) ---
const cliJs = path.join(ccDir, "cli.js");
if (fs.existsSync(cliJs)) {
  let t = fs.readFileSync(cliJs, "utf8"), changed = false;
  for (const [o, r] of tzPats) {
    if (t.includes(o)) { t = t.replace(o, r); changed = true; console.log("  TZ patch applied (cli.js)"); break; }
  }
  if (t.includes(SESSION_BUG) && !t.includes(SESSION_FIX)) {
    t = t.split(SESSION_BUG).join(SESSION_FIX); changed = true;
    console.log("  Session compat patch applied (cli.js)");
  }
  if (changed) {
    if (!fs.existsSync(cliJs + ".bak")) fs.copyFileSync(cliJs, cliJs + ".bak");
    fs.writeFileSync(cliJs, t, "utf8");
  } else if (t.includes(TZ_MARKER)) {
    console.log("  cli.js already patched");
  }
}

// --- Patch SEA binary (claude.exe / claude, newer versions like 2.1.202) ---
const binDir = path.join(ccDir, "bin");
const seaCandidates = ["claude.exe", "claude"].map(n => path.join(binDir, n)).filter(p => fs.existsSync(p));
for (const exe of seaCandidates) {
  const bytes = fs.readFileSync(exe);
  const text = bytes.toString("latin1");
  if (text.includes(TZ_MARKER)) { console.log("  " + path.basename(exe) + " already patched"); continue; }
  let patched = false;
  for (const [o, r] of tzPats) {
    const idx = text.indexOf(o);
    if (idx === -1) continue;
    if (!fs.existsSync(exe + ".bak")) fs.copyFileSync(exe, exe + ".bak");
    const buf = Buffer.from(r, "latin1");
    buf.copy(bytes, idx);
    fs.writeFileSync(exe, bytes);
    console.log("  TZ patch applied (" + path.basename(exe) + ")");
    patched = true;
    break;
  }
  if (!patched) { console.log("  TZ patch skipped — signature not found in " + path.basename(exe)); }
}

if (!fs.existsSync(cliJs) && seaCandidates.length === 0) {
  console.log("  No patchable files found in " + ccDir);
}
