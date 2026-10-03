/** Offline, deterministic frame rendering. Requires Playwright and FFmpeg. */
import {createRequire} from 'node:module';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
const here=path.dirname(fileURLToPath(import.meta.url));
const args=process.argv.slice(2),portrait=args.includes('--portrait'),stills=args.includes('--stills'),cover43=args.includes('--cover43'),cover34=args.includes('--cover34');
const fps=60,width=portrait||cover34?1080:cover43?1440:1920,height=cover34?1440:portrait?1920:1080,label=portrait?'portrait':'landscape';
const require=createRequire(import.meta.url);
let playwright;
try{playwright=require('playwright');}catch(e){
  if(!process.env.PLAYWRIGHT_PATH)throw new Error('Install Playwright locally, or set PLAYWRIGHT_PATH to its package directory.',{cause:e});
  playwright=require(process.env.PLAYWRIGHT_PATH);
}
const out=path.join(here,'output');fs.mkdirSync(out,{recursive:true});
const browser=await playwright.chromium.launch({headless:true,...(process.env.CHROMIUM_PATH?{executablePath:process.env.CHROMIUM_PATH}:{}),args:['--enable-unsafe-swiftshader','--allow-file-access-from-files']});
const errors=[];
let encoder;
try{
 const page=await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
 page.on('pageerror',e=>errors.push(e.message));
 await page.goto(pathToFileURL(path.join(here,'index.html')).href+'?render'+(portrait?'&portrait':'')+(cover43?'&c43':'')+(cover34?'&c34':''));
 await page.waitForFunction(()=>window.filmReady||window.filmError,{},{timeout:30000});
 const ready=await page.evaluate(()=>({ready:window.filmReady,error:window.filmError,info:window.filmInfo}));
 if(!ready.ready||errors.length)throw new Error(JSON.stringify({ready,errors}));
 console.log(JSON.stringify(ready.info));
 if(cover43||cover34){
   // The 4:3 / 3:4 covers: the end card, held, each card on its open submenu.
   const name=cover43?'QDuo-cover-4x3.png':'QDuo-cover-3x4.png';
   await page.evaluate(t=>window.renderAt(t),ready.info.duration-0.2);
   await page.screenshot({path:path.join(out,name)});
   console.log('Rendered '+name);
 }else if(stills){
   for(const t of [37.5]){
     await page.evaluate(t=>window.renderAt(t),t);
     await page.screenshot({path:path.join(out,`${label}-${t.toFixed(2)}.png`)});
   }
   console.log(`Rendered ${label} proof frames.`);
 }else{
   const silent=path.join(out,`${label}-silent.mp4`);
   encoder=spawn('ffmpeg',['-y','-hide_banner','-loglevel','error','-f','image2pipe','-vcodec','mjpeg','-framerate',String(fps),'-i','pipe:0','-an','-c:v','libx264','-preset','fast','-crf','16','-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-movflags','+faststart',silent],{stdio:['pipe','inherit','inherit']});
   let encoderError;
   encoder.on('error',e=>encoderError=e);encoder.stdin.on('error',e=>encoderError=e);
   const finished=once(encoder,'close');
   const start=Date.now();
   const total=Math.round(ready.info.duration*fps);
   for(let frame=0;frame<total;frame++){
     if(encoderError)throw encoderError;
     await page.evaluate(t=>window.renderAt(t),frame/fps);
     const buffer=await page.screenshot({type:'jpeg',quality:96,animations:'allow'});
     if(!encoder.stdin.write(buffer))await once(encoder.stdin,'drain');
     if(frame%120===0)console.log(`${label}: ${frame}/${total} frames; ${((Date.now()-start)/1000).toFixed(1)}s`);
     if(errors.length)throw new Error(errors.join('\n'));
   }
   encoder.stdin.end();const [code]=await finished;if(code!==0)throw new Error(`FFmpeg exited ${code}`);
   const target=path.join(out,`QDuo-${portrait?'1080x1920':'1920x1080'}.mp4`);
   const mux=spawn('ffmpeg',['-y','-hide_banner','-loglevel','error','-i',silent,'-i',path.join(here,'assets/audio/mix.wav'),'-map','0:v:0','-map','1:a:0','-c:v','copy','-c:a','aac','-b:a','256k','-t',String(ready.info.duration),'-movflags','+faststart',target],{stdio:'inherit'});
   const [muxCode]=await once(mux,'close');if(muxCode!==0)throw new Error(`Audio mux failed (${muxCode})`);
   fs.unlinkSync(silent);console.log(`DONE ${target}`);
 }
 if(errors.length)throw new Error(errors.join('\n'));
}finally{
 if(encoder&&encoder.exitCode===null)encoder.kill('SIGTERM');
 await browser.close();
}
