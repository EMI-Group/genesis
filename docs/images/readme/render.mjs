// Original diagrams for the README, using the website's black / grey / red palette.
// Render PNG frames with: node render.mjs [path-to-sharp-module]
// Encode frames with a GIF encoder at 10 fps; frames live in the supplied temp dir.
import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const sharp = require(process.argv[2] || 'sharp');
const dest = dirname(fileURLToPath(import.meta.url));
const frames = process.argv[3];
const red = '#c8383c', white = '#f5f5f7', muted = '#a9aaaf';
const text = (x,y,s,size=22,color=white,anchor='start',weight=400) => `<text x="${x}" y="${y}" fill="${color}" font-size="${size}" text-anchor="${anchor}" font-weight="${weight}">${s}</text>`;
const wrap = (body,h=580) => `<svg xmlns="http://www.w3.org/2000/svg" width="960" height="${h}" viewBox="0 0 960 ${h}" role="img"><rect width="960" height="${h}" rx="24" fill="#08090b"/><rect x="1" y="1" width="958" height="${h-2}" rx="23" fill="none" stroke="#303136"/><g font-family="Arial, sans-serif">${body}</g></svg>`;
const ease = (t,start,end) => Math.max(0,Math.min(1,(t-start)/(end-start)));
function tree(t,still=false) {
  const managers = still ? 1 : ease(t,1.2,2.4);
  const workers = still ? 1 : ease(t,3,4.4);
  const accepted = still ? 1 : ease(t,6.3,7.5);
  const fade = still ? 1 : 1 - ease(t,8.1,9.3)*.64 + ease(t,10.1,11)*.64;
  const labels = ['01  Set an objective','02  Delegate local work','03  Implement and validate','04  Carry accepted results forward','05  Continue from the accepted world'];
  const stage = t<1.2?0:t<3?1:t<6.3?2:t<9.3?3:4;
  const edge=(x1,y1,x2,y2,opacity=1)=>`<path d="M${x1} ${y1} C${(x1+x2)/2} ${y1},${(x1+x2)/2} ${y2},${x2} ${y2}" fill="none" stroke="${red}" stroke-width="2.5" opacity="${opacity}"/>`;
  const node=(x,y,label,opacity=1,active=false)=>`<g opacity="${opacity}"><circle cx="${x}" cy="${y}" r="${active?23:17}" fill="#151518" stroke="${active?red:'#b0b0b6'}" stroke-width="2.5"/><circle cx="${x}" cy="${y}" r="5" fill="${active?red:white}"/>${text(x,y+43,label,22,white,'middle')}</g>`;
  let b=text(40,52,'The hierarchy unfolds itself.',32,white,'start',600)+text(40,86,'Transient agents. Persistent software.',22,muted);
  b+=`<g opacity="${fade}">`;
  b+=edge(142,230,330,160,managers)+edge(142,230,330,310,managers);
  b+=edge(370,160,630,125,workers)+edge(370,160,630,235,workers)+edge(370,310,800,310,workers);
  b+=node(120,230,'Objective',1,true)+node(350,160,'Manager',managers)+node(350,310,'Manager',managers);
  b+=node(650,125,'Build',workers,t>=3&&t<6.3)+node(650,235,'Test',workers,t>=3&&t<6.3)+node(820,310,'Implement',workers,t>=3&&t<6.3);
  b+='</g><path d="M40 390 H920" stroke="#303136"/>';
  b+=text(40,428,'ACCEPTED HISTORY',17,muted,'start',600);
  b+=`<path d="M128 480 H340" stroke="#44454b" stroke-width="3"/><path d="M128 480 H${128+212*accepted}" stroke="${red}" stroke-width="3"/>`;
  b+=`<circle cx="120" cy="480" r="9" fill="${white}"/>`+text(120,520,'Version 1',20,muted,'middle');
  b+=`<g opacity="${accepted}"><circle cx="350" cy="480" r="11" fill="${red}"/>${text(350,520,'Version 2',20,white,'middle')}${text(440,487,'The next episode starts here.',24,white)}</g>`;
  b+=text(40,562,still?'Local work unfolds. Accepted contributions carry forward.':labels[stage],20,muted);
  return wrap(b);
}
await writeFile(join(dest,'recursive-world.svg'),tree(8,true));
await sharp(Buffer.from(tree(8,true))).png().toFile(join(dest,'recursive-world.png'));
if(frames){
  await mkdir(frames,{recursive:true});
  for(let i=0;i<120;i++) await sharp(Buffer.from(tree(i/10))).png().toFile(join(frames,`frame-${String(i).padStart(3,'0')}.png`));
}
let a=text(40,52,'Built for long-running development.',32,white,'start',600)+text(40,87,'Three layers, each with one job.',22,muted);
const cards=[['01','desktop','Tauri / Rust','Start and supervise the backend.'],['02','evo_dash','Phoenix LiveView','Watch agents, inspect tasks, review diffs.'],['03','evo_git','Elixir / OTP','Schedule agents and manage Git worktrees.']];
for(let i=0;i<3;i++){
  const y=118+i*112;
  a+=`<rect x="40" y="${y}" width="880" height="92" rx="14" fill="#121315" stroke="#303136"/><path d="M40 ${y+20} V${y+72}" stroke="${red}" stroke-width="3"/>`;
  a+=text(64,y+39,cards[i][0],18,red,'start',600)+text(108,y+38,cards[i][1],25,white,'start',600)+text(108,y+66,cards[i][2],19,muted)+text(385,y+53,cards[i][3],22,white);
  if(i<2) a+=`<path d="M480 ${y+94} V${y+109} M475 ${y+104} L480 ${y+109} L485 ${y+104}" fill="none" stroke="#77787e" stroke-width="2"/>`;
}
await writeFile(join(dest,'architecture.svg'),wrap(a,468));
await sharp(Buffer.from(wrap(a,468))).png().toFile(join(dest,'architecture.png'));
const mobileWrap = (body,h=740) => wrap(body,h).replace('width="960"','width="540"').replace('0 0 960','0 0 540').replace('width="960"','width="540"').replace('width="958"','width="538"');
function mobileTree(t,still=false){
  const m=still?1:ease(t,1.2,2.4), w=still?1:ease(t,3,4.4), v=still?1:ease(t,6.3,7.5);
  const fade=still?1:1-ease(t,8.1,9.3)*.64+ease(t,10.1,11)*.64;
  const edge=(x,y,X,Y,o)=>`<path d="M${x} ${y} C${x} ${(y+Y)/2},${X} ${(y+Y)/2},${X} ${Y}" stroke="${red}" stroke-width="2.5" fill="none" opacity="${o}"/>`;
  const n=(x,y,label,o=1,active=false)=>`<g opacity="${o}"><circle cx="${x}" cy="${y}" r="19" fill="#151518" stroke="${active?red:'#b0b0b6'}" stroke-width="2.5"/><circle cx="${x}" cy="${y}" r="5" fill="${active?red:white}"/>${text(x,y+43,label,24,white,'middle')}</g>`;
  let b=text(30,48,'The hierarchy unfolds itself.',29,white,'start',600)+text(30,82,'Transient agents. Persistent software.',22,muted);
  b+=`<g opacity="${fade}">`+edge(270,207,150,250,m)+edge(270,207,390,250,m)+edge(150,330,90,370,w)+edge(150,330,245,370,w)+edge(390,330,440,370,w);
  b+=n(270,146,'Objective',1,true)+n(150,270,'Manager',m)+n(390,270,'Manager',m)+n(90,390,'Build',w)+n(245,390,'Test',w)+n(440,390,'Implement',w)+'</g>';
  b+='<path d="M30 478 H510" stroke="#303136"/>'+text(30,518,'ACCEPTED HISTORY',20,muted,'start',600);
  b+=`<path d="M80 564 H270" stroke="#44454b" stroke-width="3"/><path d="M80 564 H${80+190*v}" stroke="${red}" stroke-width="3"/><circle cx="70" cy="564" r="9" fill="${white}"/>`+text(70,604,'Version 1',22,muted,'middle');
  b+=`<g opacity="${v}"><circle cx="280" cy="564" r="11" fill="${red}"/>${text(280,604,'Version 2',22,white,'middle')}${text(30,652,'The next episode starts here.',25,white)}</g>`;
  const labels=['01  Set an objective','02  Delegate local work','03  Implement and validate','04  Carry accepted results forward','05  Continue from the accepted world'];
  b+=text(30,716,still?'Accepted contributions carry forward.':labels[t<1.2?0:t<3?1:t<6.3?2:t<9.3?3:4],22,muted);
  return mobileWrap(b);
}
await writeFile(join(dest,'recursive-world-mobile.svg'),mobileTree(8,true));
await sharp(Buffer.from(mobileTree(8,true))).png().toFile(join(dest,'recursive-world-mobile.png'));
if(frames){
  await mkdir(join(frames,'mobile'),{recursive:true});
  for(let i=0;i<120;i++) await sharp(Buffer.from(mobileTree(i/10))).png().toFile(join(frames,'mobile',`frame-${String(i).padStart(3,'0')}.png`));
}
let mobileArch=text(30,48,'Built for long-running',30,white,'start',600)+text(30,85,'development.',30,white,'start',600)+text(30,124,'Three layers, each with one job.',23,muted);
const roles=[['Start and supervise','the backend.'],['Watch agents, inspect tasks,','review diffs.'],['Schedule agents and manage','Git worktrees.']];
for(let i=0;i<3;i++){
  const y=158+i*170;
  mobileArch+=`<rect x="30" y="${y}" width="480" height="148" rx="14" fill="#121315" stroke="#303136"/><path d="M30 ${y+20} V${y+128}" stroke="${red}" stroke-width="3"/>`;
  mobileArch+=text(52,y+37,cards[i][0],19,red,'start',600)+text(94,y+37,cards[i][1],27,white,'start',600)+text(94,y+66,cards[i][2],21,muted)+text(52,y+103,roles[i][0],24)+text(52,y+130,roles[i][1],24);
  if(i<2) mobileArch+=`<path d="M270 ${y+150} V${y+168} M265 ${y+163} L270 ${y+168} L275 ${y+163}" fill="none" stroke="#77787e" stroke-width="2"/>`;
}
await writeFile(join(dest,'architecture-mobile.svg'),mobileWrap(mobileArch,680));
console.log('Rendered diagrams and animation frames.');
