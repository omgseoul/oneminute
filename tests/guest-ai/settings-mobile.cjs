const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const root=process.cwd();
(async()=>{
 const server=http.createServer((req,res)=>{const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname);if(name==='/before.html'){res.end('<a href="guest-ai-settings.html">AI 설정</a>');return;}const file=path.join(root,name);if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return;}try{let body=fs.readFileSync(file);if(name==='/owner-settings.html')body=body.toString().replace(/<script[\s\S]*?<\/script>/g,'').replace('omg-booting property-settings-page','property-settings-page');res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(body);}catch{res.writeHead(404).end();}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port,browser=await chromium.launch({headless:true});
 try{
  const errors=[],nativeDialogs=[];
  const state={ok:true,settings:{enabled:true,mode:'always',prompt:'숙소 안내 DATA를 참고해 정중하게 답변하세요. '.repeat(80),data:[{title:'위치',answer:'테스트 숙소'}]},default_prompt:'기본 안내',usage:{balance:991.612,used:8.388,monthly_limit:1000,available:991.612,enabled:true},history:[],provider_ready:true,qr_enabled:true};
  async function setup(width,height){const p=await browser.newPage({viewport:{width,height}});p.on('pageerror',e=>errors.push(e.message));p.on('dialog',async d=>{nativeDialogs.push(d.type());await d.dismiss();});await p.addInitScript(()=>{window.OMGNative={};window.omgSession={require:async()=>({sessionKind:'owner',accessToken:'fixture'})};});await p.route('**/*',r=>{const u=r.request().url();if(u.includes('supabase-client.js')||u.startsWith('https://cdn.'))return r.fulfill({body:''});if(u.includes('/functions/v1/guest-ai'))return r.fulfill({json:state});return u.startsWith(base)?r.continue():r.abort();});return p;}
  for(const [width,height] of [[320,740],[360,768],[412,840],[760,900],[640,360]]){
   const p=await setup(width,height);await p.goto(base+'/before.html');await p.click('a');await p.locator('#aiForm').waitFor({state:'visible'});
   const channel=await p.locator('.ai-channels').evaluate(el=>{const labels=[...el.children],a=labels.map(x=>x.getBoundingClientRect());return {sameRow:a[0].top===a[1].top,noOverflow:labels.every(x=>x.scrollWidth<=x.clientWidth),disabled:labels[1].querySelector('input').disabled};});assert(channel.sameRow&&channel.noOverflow&&channel.disabled,JSON.stringify({width,channel}));
   await p.evaluate(()=>scrollTo(0,document.documentElement.scrollHeight));const save=await p.locator('#saveAI').boundingBox();assert(save.y+save.height<=height-48,`${width} save above system bar`);
   await p.locator('#openPrompt').click();await p.locator('#promptDialog').evaluate(el=>el.scrollTop=el.scrollHeight);const done=await p.locator('#promptDialog [data-close]').last().boundingBox(),dialog=await p.locator('#promptDialog').boundingBox();assert(done.y+done.height<=height-48&&dialog.y>=28,`${width} prompt fits safe viewport`);
   assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
   if(width===360){await p.screenshot({path:'/tmp/oms-ai-prompt-compact.png'});}
   await p.locator('#promptDialog [data-close]').last().click();await p.locator('#openData').click();await p.locator('#dataDialog').evaluate(el=>el.scrollTop=el.scrollHeight);const dataDone=await p.locator('#dataDialog [data-close]').last().boundingBox();assert(dataDone.y+dataDone.height<=height-48,`${width} DATA button clear of system bar`);await p.locator('#dataDialog [data-close]').last().click();
   if(width===360){await p.evaluate(()=>scrollTo(0,0));await p.screenshot({path:'/tmp/oms-ai-settings-compact.png',fullPage:true});}
   await p.close();
  }
  const p=await setup(360,768);await p.goto(base+'/before.html');await p.click('a');await p.locator('#aiForm').waitFor({state:'visible'});await p.locator('#aiEnabled').uncheck();
  await p.locator('.back').click();await p.locator('#aiLeaveDialog').waitFor({state:'visible'});await p.click('#aiStay');assert.equal(await p.locator('#aiEnabled').isChecked(),false);assert(p.url().includes('guest-ai-settings.html'));
  // A hardware/browser Back asks in the themed dialog; Cancel preserves the editor and URL.
  await p.evaluate(()=>history.back());await p.locator('#aiLeaveDialog').waitFor({state:'visible'});await p.click('#aiStay');assert(p.url().includes('guest-ai-settings.html'));
  await p.locator('#openPrompt').click();await p.locator('#aiPrompt').fill('수정한 안내');await p.evaluate(()=>history.back());await p.locator('#promptDialog').waitFor({state:'hidden'});assert.equal(await p.locator('#aiPrompt').inputValue(),'수정한 안내');
  await p.evaluate(()=>history.back());await p.locator('#aiLeaveDialog').waitFor({state:'visible'});await p.screenshot({path:'/tmp/oms-ai-leave-compact.png'});await p.click('#aiLeave');await p.waitForURL('**/before.html');
  // A forward navigation back to settings and a saved form must not strand Back.
  await p.click('a');await p.locator('#aiForm').waitFor({state:'visible'});await p.locator('#aiEnabled').uncheck();await p.click('#saveAI');await p.waitForFunction(()=>document.getElementById('status').textContent.includes('저장했습니다'));await p.evaluate(()=>history.back());await p.waitForURL('**/before.html');
  // Link confirmation also bypasses the native beforeunload warning after consent.
  await p.click('a');await p.locator('#aiForm').waitFor({state:'visible'});await p.locator('#aiEnabled').uncheck();await p.locator('.back').click();await p.locator('#aiLeaveDialog').waitFor({state:'visible'});await p.click('#aiLeave');await p.waitForURL('**/owner-settings.html');
  const menus=await p.locator('.card>summary .help,.card>a .help').evaluateAll(els=>els.map(el=>getComputedStyle(el).marginBottom));assert(menus.length>=5&&menus.every(x=>x==='0px'));await p.screenshot({path:'/tmp/oms-owner-settings-compact.png',fullPage:true});
  assert.deepEqual(nativeDialogs,[]);assert.deepEqual(errors,[]);console.log('PASS: 320–760px and landscape safe buttons, single-row channels, compact cards, themed link/device Back confirmation, cancel retains edits, editor Back closes modal, save/back and confirmed navigation');await p.close();
 }finally{await browser.close();server.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
