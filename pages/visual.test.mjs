import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFileSync,existsSync,mkdirSync} from 'node:fs';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
import worker from './_worker.js';

const base=dirname(fileURLToPath(import.meta.url));
const origin='http://127.0.0.1';
const resources={
  '/index.html':['text/html',readFileSync(join(base,'index.html'))],
  '/style.css':['text/css',readFileSync(join(base,'style.css'))],
  '/app.js':['application/javascript',readFileSync(join(base,'app.js'))],
};
const mime='text/plain; charset=utf-8';
const env={
  REDIRECT_URL:'https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1',
  ASSETS:{
    fetch:async request=>{
      const path=new URL(request.url).pathname;
      const data=resources[path];
      if(!data)return new Response('Asset not found',{status:404});
      return new Response(request.method==='HEAD'?null:data[1],{
        status:200,headers:{'Content-Type':data[0]}
      });
    }
  }
};
const server=createServer(async(req,res)=>{
  try {
    const url=new URL(req.url,origin);
    const request=new Request(url,{method:req.method,headers:req.headers});
    const result=await worker.fetch(request,env);
    res.writeHead(result.status,Object.fromEntries(result.headers.entries()));
    res.end(req.method==='HEAD'?undefined:Buffer.from(await result.arrayBuffer()));
  }catch(error){
    console.error('Preview server error',error);
    res.writeHead(500,{'Content-Type':mime});res.end('Preview error');
  }
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const port=server.address().port;
const url=`http://127.0.0.1:${port}`;
const output=process.env.WINDOWSBRIDGE_VISUAL_DIR||join(base,'visual-output');
mkdirSync(output,{recursive:true});
const candidates=[
  process.env.CHROME_BIN,
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium'
].filter(Boolean);
const executablePath=candidates.find(existsSync);
let browser;
try {
  browser=await chromium.launch({
    ...(executablePath?{executablePath}:{}),
    headless:true,args:['--no-sandbox']
  });
  for(const size of [{width:1440,height:900,name:'desktop'},
                     {width:390,height:844,name:'mobile'},
                     {width:320,height:740,name:'small-mobile'}]){
    const context=await browser.newContext({
      viewport:{width:size.width,height:size.height},
      deviceScaleFactor:1,
      permissions:['clipboard-read','clipboard-write'],
    });
    const page=await context.newPage();
    const errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
    page.on('request',request=>{
      if(!request.url().startsWith(url+'/'))errors.push('Unexpected external fetch: '+request.url());
    });
    const response=await page.goto(url+'/',{waitUntil:'networkidle'});
    assert.equal(response?.status(),200);
    assert.match(response.headers()['content-type']||'',/text\/html/);
    assert.equal(await page.title(),'WindowsBridge — Windows и ChatGPT');
    await page.locator('#hero-title').waitFor({state:'visible'});
    await page.locator('.terminal-card').waitFor({state:'visible'});
    const diagnostics=await page.evaluate(()=>({
      pageWidth:document.documentElement.scrollWidth,
      viewportWidth:window.innerWidth,
      dark:getComputedStyle(document.body).backgroundColor,
      cssLoaded:getComputedStyle(document.querySelector('.terminal-card')).borderRadius!=='0px',
      steps:document.querySelectorAll('.step-card').length,
      labels:[...document.querySelectorAll('.step-card h3')].map(x=>x.textContent)
    }));
    assert.ok(diagnostics.pageWidth<=diagnostics.viewportWidth,
      `Horizontal overflow on ${size.name}: ${JSON.stringify(diagnostics)}`);
    assert.ok(diagnostics.cssLoaded,`Styles did not load on ${size.name}`);
    assert.equal(diagnostics.dark,'rgb(8, 13, 22)');
    assert.equal(diagnostics.steps,3);
    assert.equal(errors.length,0,`Browser errors: ${errors.join('; ')}`);
    await page.screenshot({path:join(output,`windowsbridge-${size.name}.png`),fullPage:true});
    if(size.name==='desktop'){
      await page.getByRole('button',{name:/Скопировать команду/}).click();
      const clipboard=await page.evaluate(()=>navigator.clipboard.readText());
      assert.ok(clipboard.startsWith('powershell.exe -NoProfile'));
      assert.ok(clipboard.includes('/stable/install.ps1'));
      assert.ok(!clipboard.includes('main/install.ps1'));
      assert.ok(!clipboard.includes('sk-'));
      await page.getByRole('status').getByText(/Команда скопирована/).waitFor({state:'visible'});
      const links=await page.locator('a[href^="https://"]').count();
      assert.ok(links>=4);
    }
    console.log(`VISUAL PASS ${size.name}: ${size.width}x${size.height}, no overflow, 3 steps, dark CSS, zero console errors`);
    await context.close();
  }
  console.log('WindowsBridge browser/clipboard/visual E2E simulation PASS; screenshots in '+output);
}finally{
  await browser?.close();
  await new Promise(resolve=>server.close(resolve));
}
