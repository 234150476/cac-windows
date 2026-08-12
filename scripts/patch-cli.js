const fs = require("fs");
const path = require("path");
const ccDir = process.argv[2] || path.join(process.env.APPDATA, "npm", "node_modules", "@anthropic-ai", "claude-code");

const TZ_MARKER = 'Intl.DateTimeFormat("sv"';
const tzPats = [
  ['function fys(){let e=new Date,t=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),n=String(e.getDate()).padStart(2,"0");return`${t}-${r}-${n}`}',
   'function fys(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                }'],
];

const PRIVACY_MARKER = 'mss=process.env.TZ';
const privacyPats = [
  ['function yss(){if(!mss)mss=Intl.DateTimeFormat().resolvedOptions().timeZone;return mss}',
   'function yss(){if(!mss)mss=process.env.TZ||"UTC"                           ;return mss}'],
  ['function Zsu(){if(rpo===null)try{let e=Intl.DateTimeFormat().resolvedOptions().locale;rpo=new Intl.Locale(e).language}catch{rpo=void 0}return rpo}',
   'function Zsu(){if(rpo===null)rpo="en";                                                                                                 return rpo}'],
  ['let l=Intl.DateTimeFormat().resolvedOptions().timeZone',
   'let l=process.env.TZ||"UTC"                           '],
  ['.toLocaleDateString(void 0,{year:"numeric",month:"short",day:"numeric"})',
   '.toLocaleDateString( "en" ,{year:"numeric",month:"short",day:"numeric"})'],
];
const akmOriginal = 'i=-n.getTimezoneOffset(),s=Math.floor(Math.abs(i)/60),a=Math.abs(i)%60,c=`${i>=0?"+":"-"}${String(s).padStart(2,"0")}:${String(a).padStart(2,"0")}`';
const akmReplace  = 'i=0                                                                                                                             ,s=0,a=0,c="+00:00"';

const binDir = path.join(ccDir, "bin");
const seaCandidates = ["claude.exe", "claude"].map(n => path.join(binDir, n)).filter(p => fs.existsSync(p));

if (seaCandidates.length === 0) {
  console.log("  No patchable binary found in " + binDir);
  process.exit(0);
}

for (const exe of seaCandidates) {
  let bytes = fs.readFileSync(exe);
  let text = bytes.toString("latin1");
  let anyChange = false;

  // TZ date patch
  if (text.includes(TZ_MARKER)) {
    console.log("  TZ patch already applied (" + path.basename(exe) + ")");
  } else {
    for (const [o, r] of tzPats) {
      const idx = text.indexOf(o);
      if (idx === -1) continue;
      if (!fs.existsSync(exe + ".bak")) fs.copyFileSync(exe, exe + ".bak");
      Buffer.from(r, "latin1").copy(bytes, idx);
      anyChange = true;
      console.log("  TZ patch applied (" + path.basename(exe) + ")");
      break;
    }
    if (!anyChange) { console.log("  TZ patch skipped — signature not found in " + path.basename(exe)); }
    if (anyChange) {
      fs.writeFileSync(exe, bytes);
      text = bytes.toString("latin1");
    }
  }

  // Privacy patches
  if (text.includes(PRIVACY_MARKER)) {
    console.log("  Privacy patches already applied (" + path.basename(exe) + ")");
  } else {
    if (anyChange) {
      bytes = fs.readFileSync(exe);
      text = bytes.toString("latin1");
    }
    let privacyChanged = false;
    for (const [o, r] of privacyPats) {
      const pidx = text.indexOf(o);
      if (pidx === -1 || o.length !== r.length) continue;
      Buffer.from(r, "latin1").copy(bytes, pidx);
      privacyChanged = true;
    }
    const akmIdx = text.indexOf(akmOriginal);
    if (akmIdx !== -1 && akmOriginal.length === akmReplace.length) {
      Buffer.from(akmReplace, "latin1").copy(bytes, akmIdx);
      privacyChanged = true;
    }
    if (privacyChanged) {
      if (!fs.existsSync(exe + ".bak") && !anyChange) fs.copyFileSync(exe, exe + ".bak");
      fs.writeFileSync(exe, bytes);
      console.log("  Privacy patches applied (" + path.basename(exe) + ")");
    }
  }
}
