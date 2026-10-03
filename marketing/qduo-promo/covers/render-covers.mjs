/** Render the cover pages to PNG: node covers/render-covers.mjs [page.html?query=… out.png w h] … */
import {createRequire} from 'node:module';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url));
const require=createRequire(import.meta.url);
let playwright;try{playwright=require('playwright');}catch{playwright=require(process.env.PLAYWRIGHT_PATH);}
const browser=await playwright.chromium.launch({headless:true,...(process.env.CHROMIUM_PATH?{executablePath:process.env.CHROMIUM_PATH}:{}),args:['--allow-file-access-from-files']});
const a=process.argv.slice(2);
try{
  for(let i=0;i<a.length;i+=4){
    const [page_,out,w,h]=[a[i],a[i+1],+a[i+2],+a[i+3]];
    const page=await browser.newPage({viewport:{width:w,height:h},deviceScaleFactor:1});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    const [file,q]=page_.split('?');
    await page.goto(pathToFileURL(path.join(here,file)).href+(q?'?'+q:''));
    await page.waitForFunction(()=>window.ready||window.failed,{},{timeout:20000});
    if(errors.length||await page.evaluate(()=>window.failed))throw new Error(page_+': '+errors.join('; '));
    await page.screenshot({path:path.resolve(out)});console.log('wrote',out);await page.close();
  }
}finally{await browser.close();}
