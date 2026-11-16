const fs=require('fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
(async()=>{const browser=await chromium.launch({headless:true});try{
 for(const failure of ['quota','stalled','config']){
  const page=await browser.newPage({viewport:{width:360,height:850}});await page.clock.install();
  await page.addInitScript(failure=>{
   const session={accessToken:'fixture',sessionKind:'owner',ownerId:'owner',sessionId:'session',propertyId:'p',timezone:'Asia/Seoul'};
   window.omgSession={get:()=>session,require:async()=>{if(failure==='quota')throw Object.assign(Error('exceed_egress_quota'),{status:402});if(failure==='stalled')return new Promise(()=>{});return session;}};
   window.omgWorkConfig={load:async()=>{throw Error('unavailable');}};
  },failure);
  const allowed=new Set(['page-transition.js','home-summary-state.js','home-recovery.js']);
  const html=fs.readFileSync('app.html','utf8').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(_,src)=>allowed.has(src.split('?')[0])?'<script>'+fs.readFileSync(src.split('?')[0],'utf8')+'</script>':'');
  await page.route('**/*',r=>{const name=new URL(r.request().url()).pathname.slice(1);if(name==='app.html')return r.fulfill({contentType:'text/html',body:html});return fs.existsSync(name)&&fs.statSync(name).isFile()?r.fulfill({path:name}):r.fulfill({status:204,body:''});});
  await page.goto('https://omgworks24.com/app.html');if(failure==='stalled')await page.clock.fastForward(17000);
  await page.getByRole('button',{name:'다시 시도'}).waitFor();assert(await page.locator('#mainMenu').evaluate(e=>getComputedStyle(e).visibility==='hidden'),'unverified role must not expose staff defaults');
  for(const id of ['todayOverviewItems','homeCleaning','workingGrid'])assert(!(await page.locator('#'+id).textContent()).includes('불러오는 중'));
  assert((await page.locator('#homeCleaning').boundingBox()).height<90,'failure text spans the grid, not the broom column');
  if(failure==='quota'){assert((await page.locator('#homeServiceStatus').textContent()).includes('한도'));await page.screenshot({path:'/tmp/oms-home-recovery.png'});}
  await page.close();
 }
 // A stalled optional request must expire, retain existing data and reject late paints.
 const page=await browser.newPage();await page.goto('about:blank');await page.addScriptTag({content:fs.readFileSync('home-summary-state.js','utf8')});
 const result=await page.evaluate(async()=>{let finish,errors=0,paint=0;const c=OMSHomeState.channel(async(_,current)=>{await new Promise(r=>finish=r);if(current())paint++;},{timeout:30,onError:()=>errors++});await c.refresh();finish();await Promise.resolve();return{errors,paint};});assert.deepEqual(result,{errors:1,paint:0});
 console.log('PASS 402, stalled session, config failure, role-safe layout, visible retry, compact error text and late-reply protection');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
