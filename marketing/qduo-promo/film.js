/* A deterministic 20-second film: every visual is a pure function of timeline time.
 *
 * The product on screen is never drawn here. Every ring, capsule and panel is the
 * real QDuo popup, recorded from the app (see capture/README.md) and played back
 * frame by frame; this file only places those recordings, moves a camera over
 * them, and sets the type around them. */
(()=>{
'use strict';
const query=new URLSearchParams(location.search), portrait=query.has('portrait')||query.has('c34'), render=query.has('render');
const $=id=>document.getElementById(id), film=$('film');
// `c43`: a 4:3 landscape frame (1440 × 1080), used for the 4:3 cover.
const c43=query.has('c43'),c34=query.has('c34');film.classList.toggle('c43',c43);film.classList.toggle('c34',c34);
film.classList.toggle('portrait',portrait);document.body.classList.toggle('render',render);
const W=portrait?1080:c43?1440:1920,H=c34?1440:portrait?1920:1080;
const CUES=window.CUES, FRAMES=window.FRAMES||{};
const clamp=(v,a=0,b=1)=>Math.min(b,Math.max(a,v));
const ease=x=>{x=clamp(x);return 1-Math.pow(1-x,3);};
const smooth=x=>{x=clamp(x);return x*x*(3-2*x);};
const inOut=x=>{x=clamp(x);return x<.5?4*x*x*x:1-Math.pow(-2*x+2,3)/2;};
const lerp=(a,b,x)=>a+(b-a)*x;
const enter=(t,start,d=.5)=>ease((t-start)/d);

function copy(kicker,title,desc,extra=''){return `<div class="copy"><div class="eyebrow">${kicker}</div><h1>${title}</h1><p>${desc}</p>${extra}</div>`;}
function tag(t){return `<div class="style-tag"><i></i>${t}</div>`;}
const html={
 intro:copy('YOUR NEXT MOVE','选中。<br><em>即刻行动。</em>','每一段文字，都有更多可能。',tag('Liquid Glass · 水玻璃')),
 translate:copy('01 / TRANSLATE','跨越<br><em>语言。</em>','翻译，就在原地。',tag('Liquid Glass · 水玻璃')),
 dimension:copy('DESIGNED TO FEEL RIGHT','好看。<br><em>更顺手。</em>','跟随光标，感受真实的立体层次。','<div class="style-switch"><span>Liquid</span><span class="on">3D Glass</span><span>Capsule</span></div>'),
 write:copy('02 / WRITE','让想法，<br><em>成为文字。</em>','从几个要点，到一段完整表达。',tag('自定义 AI 动作 · 写作')),
 polish:copy('03 / POLISH','表达，<br><em>再好一点。</em>','看清修改，一键替换。',tag('Capsule · 横向胶囊')),
 read:copy('04 / LISTEN','让文字，<br><em>读给你听。</em>','目光跟随，灵感继续。',tag('Capsule · 横向胶囊')),
 end:`<div class="end-top"><div class="end-brand"><img src="assets/icon.png" alt="QDuo 图标"><b>QDuo</b></div><h1>下一步，就在手边。</h1></div><div class="end-styles">${['Liquid Glass','3D Glass','Capsule'].map((n,i)=>`<div class="style-card"><div class="card-shot"><img id="card-${i}" alt=""></div><div class="style-name">${n}</div></div>`).join('')}</div><div class="end-bottom">翻译 · 写作 · 润色 · 朗读 · 还有更多，由你定义<span>自定义 AI 提示词 · 快捷指令 · Shell 脚本 · 网页搜索 · 分组二级菜单</span></div>`
};
const scenes=CUES.scenes;
$('scenes').innerHTML=scenes.map(s=>`<section class="scene" id="scene-${s.id}">${html[s.id]}</section>`).join('');
$('chapters').innerHTML=['翻译','写作','润色','朗读'].map((t,i)=>`<span data-chapter="${i}"><i></i>${t}</span>`).join('');

// ---- Recorded frames ------------------------------------------------------
// A take is 2 image pixels per screen point; frame N (1-based) is take time (N-1)/60.
const PX=2;
// The document page inside every take (take points): its window minus the title bar.
const PAGE=[71,110,829,589];
function frameURL(take,t){const n=clamp(Math.floor(t*60+1e-6)+1,1,FRAMES[take]||1);return `frames/${take}/${String(n).padStart(4,'0')}.jpg`;}
function takeTime(shot,t){const m=shot.map;if(t<=m[0][0])return m[0][1]+(t-m[0][0]);for(let i=1;i<m.length;i++)if(t<=m[i][0]){const [f0,k0]=m[i-1],[f1,k1]=m[i];return lerp(k0,k1,(t-f0)/(f1-f0));}const [f,k]=m[m.length-1];return k+(t-f);}
const pending=[];
function setFrame(img,url){if(img.dataset.url===url)return;img.dataset.url=url;img.src=url;// While rendering, a missing or broken frame must fail the render, not repeat the last one.
  pending.push(render?img.decode():img.decode().catch(()=>{}));}
/** Point a camera at take point (cx, cy) with `z` film pixels per take point. */
function aim(img,box,cx,cy,z){const s=z/PX;img.style.transform=`translate(${box[0]/2-cx*z}px,${box[1]/2-cy*z}px) scale(${s})`;}

// ---- Cameras (take points; the take's origin is the top-left of its shot) ---
// Keys: [film t, cx, cy, z]. Between keys the camera eases; it holds after the last.
const cams={
 liquid:[[0,420,330,1.45],[1.3,419,368,1.45],[1.85,419,374,2.0],[2.95,419,374,2.0],[3.4,419,408,1.85],[4.2,419,408,1.85],[4.7,419,374,2.0],[6.25,419,374,2.0],[6.8,419,280,1.7]],
 donut:[[8.2,300,330,1.5],[8.65,302,370,2.05],[9.75,302,370,2.05],[10.15,302,408,1.85],[10.9,302,408,1.85],[11.35,302,370,2.05],[13.6,302,370,2.05],[14.2,320,262,1.6]],
 polish:[[16.8,380,322,1.6],[17.2,361,337,1.95],[18.9,361,337,1.95],[19.25,361,362,1.9],[19.95,361,362,1.9],[20.3,361,337,1.95],[21.75,361,337,1.95],[22.25,361,372,1.85],[24.9,361,372,1.85],[25.4,420,345,1.8]],
 read:[[26.05,330,322,1.6],[26.45,318,337,1.95],[29.15,318,337,1.95],[29.65,318,345,1.9],[34.55,318,348,2.0]]
};
function camera(keys,t){if(t<=keys[0][0])return keys[0].slice(1);for(let i=1;i<keys.length;i++)if(t<=keys[i][0]){const a=keys[i-1],b=keys[i],x=inOut((t-a[0])/(b[0]-a[0]));return [lerp(a[1],b[1],x),lerp(a[2],b[2],x),lerp(a[3],b[3],x)];}return keys[keys.length-1].slice(1);}

// End cards: short real moments of each style, framed on the popup.
// Each card frames a box (w × h take points, centred on cx, cy) holding the whole
// popup with its open submenu, scaled to fit the card.
const cards=[
 {take:'liquid',from:3.3,to:6.2,still:4.9,cx:419,cy:404,w:330,h:340},
 {take:'donut',from:3.0,to:5.9,still:4.4,cx:302,cy:404,w:330,h:340},
 {take:'polish',from:3.4,to:6.3,still:4.9,cx:361,cy:398,w:440,h:200}
];

const shotBox=portrait?[1000,760]:[1050,760];
const shotImg=$('shot-img'),cardImgs=[0,1,2].map(i=>$('card-'+i));
const clickRipple=$('ripple');

// Live preview: ask for the next half second of frames ahead of time, so the
// picture is not waiting on JPEG loads while the sound runs on.
const ahead=new Map();
function prefetch(sh,t){for(let k=2;k<=30;k+=2){const tt=t+k/60;if(tt>=sh.end)break;const u=frameURL(sh.take,takeTime(sh,tt));if(!ahead.has(u)){const im=new Image();im.src=u;im.decode().catch(()=>{});ahead.set(u,im);if(ahead.size>240)ahead.delete(ahead.keys().next().value);}}}
function sceneEnvelope(t,s){return smooth((t-s.start)/.27)*(s.id==='end'?1:1-smooth((t-(s.end-.2))/.2));}
// Same take across two scenes (intro→translate, dimension→write): the picture
// must not blink at the copy change, so the shot fades only at its own edges.
function shotEnvelope(t,sh){return (sh.start===0?1:smooth((t-sh.start)/.3))*(1-smooth((t-(sh.end-.22))/.22));}

function draw(t){
  t=clamp(t,0,CUES.duration);window.currentFilmTime=t;pending.length=0;
  scenes.forEach(s=>{const n=$('scene-'+s.id),on=t>=s.start&&(t<s.end||(s.id==='end'&&t<=s.end));n.style.visibility=on?'visible':'hidden';if(!on)return;n.style.opacity=s.id==='intro'?1:sceneEnvelope(t,s);const p=t-s.start,c=n.querySelector('.copy');if(c){c.style.transform=`translateY(${(1-enter(p,0,.6))*24}px)`;c.style.opacity=enter(p,.03,.35);}});
  document.querySelector('.ambient-a').style.transform=`translate(${Math.sin(t*.23)*70}px,${Math.cos(t*.2)*40}px)`;
  document.querySelector('.ambient-b').style.transform=`translate(${Math.cos(t*.19)*90}px,${Math.sin(t*.3)*35}px)`;
  // Footer chapters follow the scene on screen; the intro, the 3D showcase and the end light none.
  const scene=scenes.find(s=>t>=s.start&&t<s.end),ch={translate:0,write:1,polish:2,read:3}[scene&&scene.id];
  document.querySelectorAll('[data-chapter]').forEach(n=>n.classList.toggle('on',+n.dataset.chapter===ch));
  $('progress').style.width=(t/CUES.duration*100)+'%';

  // The recorded shot.
  const sh=CUES.shots.find(s=>t>=s.start&&t<s.end),box=$('shot');
  if(sh){
    const a=shotEnvelope(t,sh),p=t-sh.start;
    box.style.visibility='visible';box.style.opacity=a;
    box.style.transform=`translateY(${(1-enter(p,0,.55))*(sh.start===0?40:26)}px) scale(${lerp(.975,1,enter(p,0,.55))})`;
    setFrame(shotImg,frameURL(sh.take,takeTime(sh,t)));
    if(!render)prefetch(sh,t);
    const [cx,cy,z]=camera(cams[sh.take],t);aim(shotImg,shotBox,cx,cy,z);
    // A soft ring where the real click lands, so the eye finds it.
    const c=CUES.sfx.filter(e=>e.kind==='click'&&t>=e.t&&t<e.t+.45&&e.t>=sh.start&&e.t<sh.end)[0];
    if(c){const ev=window.CLICKS[sh.take].find(k=>Math.abs(takeTime(sh,c.t)-k.t)<.2);
      if(ev){const q=(t-c.t)/.45;clickRipple.style.opacity=(1-q)*.75;clickRipple.style.transform=`translate(${shotBox[0]/2+(ev.x-cx)*z}px,${shotBox[1]/2+(ev.y-cy)*z}px) scale(${.4+q*1.1})`;}else clickRipple.style.opacity=0;}
    else clickRipple.style.opacity=0;
  }else box.style.visibility='hidden';

  const endStart=scenes[scenes.length-1].start;
  if(t>=endStart){
    const p=t-endStart,alpha=enter(p,.05,.5);
    document.querySelectorAll('.style-card').forEach((c,i)=>{const a=enter(p,.15+i*.08,.55);c.style.opacity=a;c.style.transform=`translateY(${(1-a)*34}px)`;
      const k=cards[i],img=cardImgs[i],cb=img.parentNode;// The 4:3 cover holds each card on a moment with its submenu open.
      setFrame(img,frameURL(k.take,(c43||c34)?k.still:Math.min(k.to,k.from+Math.max(0,p-.15))));// Fit the box, but never zoom out past the page: no window edge may show.
      const [x0,y0,x1,y1]=PAGE,bw=cb.offsetWidth,bh=cb.offsetHeight,z=Math.max(Math.min(bw/k.w,bh/k.h),bw/(x1-x0),bh/(y1-y0)),hw=bw/2/z,hh=bh/2/z;
      aim(img,[bw,bh],clamp(k.cx,x0+hw,Math.max(x0+hw,x1-hw)),clamp(k.cy,y0+hh,Math.max(y0+hh,y1-hh)),z);});
    $('scene-end').querySelector('.end-top').style.transform=`translateY(${(1-alpha)*20}px)`;
    $('scene-end').querySelector('.end-bottom').style.opacity=enter(p,.6,.5);
  }
  $('seek').value=t;$('time').textContent=`0:${String(Math.floor(t)).padStart(2,'0')} / 0:${Math.ceil(CUES.duration)}`;
  return Promise.all(pending);
}
$('seek').max=CUES.duration;
window.renderAt=draw;window.filmInfo={duration:CUES.duration,width:W,height:H,fps:60,scenes:scenes.map(({id,start,end})=>({id,start,end}))};
function resize(){const s=Math.min(innerWidth/W,innerHeight/H);film.style.transform=`scale(${s})`;film.style.left=(innerWidth-W*s)/2+'px';film.style.top=(innerHeight-H*s)/2+'px';}
addEventListener('resize',resize);resize();
let playing=false,sound=false,base=0,started=0,raf;
const audio=$('audio');
function syncAudio(){audio.pause();audio.currentTime=clamp(base,0,CUES.duration-.01);if(playing&&sound)audio.play().catch(e=>{if(e.name!=='AbortError'){sound=false;$('sound').textContent='声音关';}});}
// Live preview only (the export renders each frame exactly). With sound on, the
// audio element is the clock: the picture follows what is being heard, rather
// than a wall clock the audio may lag behind while it starts.
function frame(now){if(!playing)return;const t=(sound&&!audio.paused&&!audio.seeking)?audio.currentTime:base+(now-started)/1000;if(t>=CUES.duration){playing=false;base=CUES.duration;draw(base);audio.pause();$('play').textContent='重播';return;}draw(t);raf=requestAnimationFrame(frame);}
$('play').onclick=()=>{if(playing){base=window.currentFilmTime;playing=false;cancelAnimationFrame(raf);}else{if(base>=CUES.duration)base=0;playing=true;started=performance.now();raf=requestAnimationFrame(frame);}$('play').textContent=playing?'暂停':'播放';syncAudio();};
$('seek').oninput=e=>{base=+e.target.value;started=performance.now();draw(base);syncAudio();};
$('sound').onclick=()=>{sound=!sound;base=window.currentFilmTime;started=performance.now();$('sound').textContent=sound?'声音开':'声音关';syncAudio();};
$('orientation').href=portrait?'./index.html':'?portrait';$('orientation').textContent=portrait?'横屏':'竖屏';
Promise.all([document.fonts.ready,...Array.from(document.images).filter(i=>i.src).map(i=>i.decode())])
  .then(()=>draw(query.has('t')?+query.get('t'):0)).then(()=>window.filmReady=true).catch(e=>window.filmError=String(e));
})();
