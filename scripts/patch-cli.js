const fs = require("fs");
const path = require("path");
const ccDir = process.argv[2] || path.join(process.env.APPDATA, "npm", "node_modules", "@anthropic-ai", "claude-code");
const cliJs = path.join(ccDir, "cli.js");
if (!fs.existsSync(cliJs)) { console.log("cli.js not found at " + cliJs); process.exit(0); }
let t = fs.readFileSync(cliJs, "utf8"), changed = false;
const tzPats = [
  ['function TD6(){let A=new Date,q=A.getFullYear(),K=String(A.getMonth()+1).padStart(2,"0"),Y=String(A.getDate()).padStart(2,"0");return`${q}-${K}-${Y}`}',
   'function TD6(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                 }'],
  ['function byo(){let e=new Date,t=e.getFullYear(),r=String(e.getMonth()+1).padStart(2,"0"),n=String(e.getDate()).padStart(2,"0");return`${t}-${r}-${n}`}',
   'function byo(){return new Intl.DateTimeFormat("sv",{timeZone:process.env.TZ||"UTC"}).format(new Date)                                                }'],
];
for (const [o,r] of tzPats) { if (t.includes(o)) { t = t.replace(o,r); changed = true; console.log("  TZ patch applied"); break; } }
const nb = 'firstLine:K.split(`', nf = 'firstLine:(K||"").split(`';
if (t.includes(nb) && !t.includes(nf)) { t = t.split(nb).join(nf); changed = true; console.log("  Session compat patch applied"); }
if (changed) { fs.writeFileSync(cliJs, t, "utf8"); } else { console.log("  Patches already applied or not needed"); }
