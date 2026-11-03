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
const architectureLayers=[
  ['Desktop','desktop · Tauri / Rust','Starts and supervises','the local backend.'],
  ['Dashboard','evo_dash · Phoenix LiveView','Tracks agents, tasks','and code changes.'],
  ['Runtime','evo_git · Elixir / OTP','Manages agents and','Git worktrees.'],
];
function architectureIcon(i,x,y){
  const icons=[
    '<rect x="-14" y="-11" width="28" height="20" rx="3"/><path d="M-6 15 H6 M0 9 V15 M-14 -5 H14"/>',
    '<rect x="-13" y="-12" width="10" height="10" rx="2"/><rect x="3" y="-12" width="10" height="10" rx="2"/><rect x="-13" y="4" width="10" height="10" rx="2"/><path d="M4 9 H13 M8.5 4.5 V13.5"/>',
    '<path d="M0 -12 V0 M0 0 H-12 V12 M0 0 H12 V12"/><circle cx="0" cy="-13" r="4" fill="#181216"/><circle cx="-12" cy="13" r="4" fill="#181216"/><circle cx="12" cy="13" r="4" fill="#181216"/>',
  ];
  return `<g transform="translate(${x} ${y})"><circle r="27" fill="#181216" stroke="#48272d"/><g stroke="#e05a60" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none">${icons[i]}</g></g>`;
}
function architecture(mobile=false){
  const w=mobile?540:960,h=mobile?520:278;
  let b=`<rect x=".5" y=".5" width="${w-1}" height="${h-1}" rx="18" fill="#0b0d10" stroke="#292d34"/>`;
  for(let i=0;i<3;i++){
    const [title,stack,line1,line2]=architectureLayers[i];
    if(mobile){
      const y=54+i*164;
      b+=architectureIcon(i,54,y+7)+text(110,y+2,title,30,white,'start',600)+text(110,y+34,stack,21,muted)+text(110,y+75,line1,25)+text(110,y+107,line2,25);
      if(i<2) b+=`<path d="M54 ${y+42} V${y+131}" stroke="#3a3036" stroke-width="1.5"/><path d="M49 ${y+126} L54 ${y+132} L59 ${y+126}" stroke="#8c626a" fill="none" stroke-width="1.5"/><path d="M110 ${y+136} H504" stroke="#252930"/>`;
    }else{
      const x=38+i*312;
      b+=architectureIcon(i,x+27,58)+text(x,126,title,29,white,'start',600)+text(x,158,stack,18,muted)+text(x,207,line1,23)+text(x,238,line2,23);
      if(i<2) b+=`<path d="M${x+72} 58 H${x+270}" stroke="#393038" stroke-width="1.5"/><path d="M${x+264} 53 L${x+270} 58 L${x+264} 63" stroke="#8c626a" stroke-width="1.5" fill="none"/>`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img"><g font-family="Arial, sans-serif">${b}</g></svg>`;
}
await writeFile(join(dest,'architecture.svg'),architecture());
await writeFile(join(dest,'architecture-mobile.svg'),architecture(true));
await sharp(Buffer.from(architecture())).png().toFile(join(dest,'architecture.png'));
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
console.log('Rendered diagrams and animation frames.');
// Compact companion for a 400px-wide floated README illustration.
function inlineTree(t,still=false){
  const m=still?1:ease(t,1.2,2.4),w=still?1:ease(t,3,4.4),v=still?1:ease(t,6.3,7.5);
  const fade=still?1:1-ease(t,8.1,9.3)*.64+ease(t,10.1,11)*.64;
  const line=(x,y,X,Y,o)=>`<path d="M${x} ${y} C${(x+X)/2} ${y},${(x+X)/2} ${Y},${X} ${Y}" stroke="${red}" stroke-width="2.3" fill="none" opacity="${o}"/>`;
  const dot=(x,y,label,o=1,active=false)=>`<g opacity="${o}"><circle cx="${x}" cy="${y}" r="16" fill="#151518" stroke="${active?red:'#b0b0b6'}" stroke-width="2.3"/><circle cx="${x}" cy="${y}" r="4" fill="${active?red:white}"/>${text(x,y+36,label,21,white,'middle')}</g>`;
  let b=text(28,43,'RECURSIVE WORK',19,muted,'start',600);
  b+=`<g opacity="${fade}">`+line(91,182,234,112,m)+line(91,182,234,270,m)+line(266,112,454,90,w)+line(266,112,454,187,w)+line(266,270,454,286,w);
  b+=dot(75,182,'Objective',1,true)+dot(250,112,'Manager',m)+dot(250,270,'Manager',m)+dot(470,90,'Build',w)+dot(470,187,'Test',w)+dot(470,286,'Implement',w)+'</g>';
  b+='<path d="M28 348 H532" stroke="#303136"/>'+text(28,386,'ACCEPTED HISTORY',19,muted,'start',600);
  b+=`<path d="M85 429 H300" stroke="#44454b" stroke-width="3"/><path d="M85 429 H${85+215*v}" stroke="${red}" stroke-width="3"/><circle cx="77" cy="429" r="8" fill="${white}"/>`+text(77,468,'Version 1',21,muted,'middle');
  b+=`<g opacity="${v}"><circle cx="308" cy="429" r="10" fill="${red}"/>${text(308,468,'Version 2',21,white,'middle')}</g>`;
  const labels=['Set an objective','Delegate local work','Implement and validate','Accepted results persist','Continue from the accepted world'];
  b+=text(28,510,still?'Accepted results carry forward.':labels[t<1.2?0:t<3?1:t<6.3?2:t<9.3?3:4],21,muted);
  const svg=wrap(b,536).replaceAll('width="960"','width="560"').replace('0 0 960','0 0 560').replace('width="958"','width="558"');
  return svg.replace('width="560"','width="592"').replace('0 0 560','0 0 592').replace('role="img">','role="img"><g transform="translate(16 0)">').replace('</svg>','</g></svg>');
}
await writeFile(join(dest,'recursive-world-inline.svg'),inlineTree(8,true));
await sharp(Buffer.from(inlineTree(8,true))).png().toFile(join(dest,'recursive-world-inline.png'));
if(frames){
  await mkdir(join(frames,'inline'),{recursive:true});
  for(let i=0;i<120;i++) await sharp(Buffer.from(inlineTree(i/10))).png().toFile(join(frames,'inline',`frame-${String(i).padStart(3,'0')}.png`));
}
