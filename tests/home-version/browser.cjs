const fs=require('fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
(async()=>{const browser=await chromium.launch();try{
 for(const width of [320,390])for(const scenario of ['current','new','older','offline','browser']){
  const page=await browser.newPage({viewport:{width,height:844}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(scenario=>{window.updateClicks=0;if(scenario!=='browser')window.OMGNative={getAppInfo:()=>JSON.stringify({version_name:'0.18.6',version_code:1203}),checkForUpdate:()=>updateClicks++};},scenario);
  let next=scenario==='new'?1204:scenario==='older'?1202:1203;
  await page.route('**/*',route=>{const file=new URL(route.request().url()).pathname.slice(1);
   if(file==='app.html'){let html=fs.readFileSync(file,'utf8').replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'');html=html.replace('</body>','<a data-apk-download></a><script>document.getElementById("appShell").classList.add("ready");document.documentElement.classList.remove("omg-booting");</script><script src="apk-download.js"></script></body>');return route.fulfill({contentType:'text/html',body:html});}
   if(file==='downloads/oms-update.json')return scenario==='offline'?route.abort():route.fulfill({json:{version_name:next===1204?'0.18.7':'0.18.6',version_code:next,apk_url:'https://omgworks24.com/downloads/OMS-test.apk'}});
   if(!file.includes('..')&&fs.existsSync(file)&&fs.statSync(file).isFile())return route.fulfill({path:file});return route.fulfill({status:204,body:''});
  });
  await page.goto('https://omgworks24.com/app.html');await page.waitForFunction(()=>document.getElementById('appVersion').textContent==='Ver 18.6');
  if(scenario!=='offline')await page.waitForFunction(()=>document.querySelector('[data-apk-download]').hasAttribute('href'));
  assert.equal(await page.locator('#appVersionUpdate').isVisible(),scenario==='new');
  const top=await page.locator('#appShell>.top').boundingBox(),hero=await page.locator('.oms-hero').boundingBox();
  assert.equal(top.y,8,'Home top spacing is identical in web and native bridge modes');
  assert.equal(hero.y-top.y-top.height,10,'Compact gap below home actions');
  assert(top.height>=40,'Home actions retain their touch area');
  assert.equal(await page.locator('[data-check-app-update]').count(),0);assert.equal(await page.locator('.attendance-progress').count(),0);
  const box=await page.locator('.app-version').boundingBox();assert(box.x>=0&&box.x+box.width<=width);assert.equal(await page.locator('#appVersion').evaluate(e=>getComputedStyle(e).fontSize),'10px');
  if(scenario==='new'){await page.locator('#appVersionUpdate').click();assert.equal(await page.evaluate(()=>updateClicks),1);await page.screenshot({path:'/tmp/oms-home-version-'+width+'.png'});next=1203;await page.evaluate(()=>dispatchEvent(new Event('pageshow')));await page.waitForFunction(()=>document.getElementById('appVersionUpdate').hidden);assert.equal(await page.locator('#appVersion').textContent(),'Ver 18.6');}
  assert.deepEqual(errors,[]);console.log('PASS home version '+width+' '+scenario);await page.close();
 }
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
