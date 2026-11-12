const {chromium}=require('playwright'),fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 const page=await browser.newPage({viewport:{width:360,height:740}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',route=>{
  const name=new URL(route.request().url()).pathname.slice(1);
  if(['login.html','native-login-input.js'].includes(name))return route.fulfill({body:fs.readFileSync(name),contentType:name.endsWith('.js')?'text/javascript':'text/html'});
  return route.fulfill({body:'',contentType:'text/javascript'});
 });
 await page.addInitScript(()=>{
  window.omgSession={get:()=>null};window.omgAccount={require:async()=>({user:{email:'fixture@example.test'}})};
  window.omgTransition={ready(){document.documentElement.classList.remove('omg-booting')}};
  window.omgSupabase={rpc:async(name)=>({data:name==='get_or_create_account_property'?{ok:true,onboarding_pending:true,service:{ends_at:'2026-12-12T00:00Z',limit_bytes:2147483648}}:{ok:true}})};
  window.nativeLayouts=[];window.OMSLoginInput={layout(value){window.nativeLayouts.push(JSON.parse(value))},hide(){},focus(){},value(){return 'admin'}};
 });
 await page.goto('https://omgworks24.com/login.html');await page.locator('#welcomeModal').waitFor({state:'visible'});
 for(const width of [320,360,412]){
  await page.setViewportSize({width,height:740});
  assert(await page.locator('#welcomeTitle').evaluate(e=>e.getBoundingClientRect().height<parseFloat(getComputedStyle(e).lineHeight)*1.5),'short heading stays on one line');
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  assert(await page.locator('.welcome-card').evaluate(e=>e.scrollWidth<=e.clientWidth));
  assert(!((await page.locator('#welcomeTerms').textContent()).includes('-일')));
  assert(await page.locator('#welcomeConfirm').evaluate(e=>e.getBoundingClientRect().bottom<=innerHeight-12));
 }
 await page.setViewportSize({width:360,height:740});await page.screenshot({path:'/tmp/oms-signup-welcome.png'});
 await page.waitForFunction(()=>nativeLayouts.length&&nativeLayouts.at(-1).visible===false);
 assert(await page.locator('#loginShell').evaluate(e=>e.inert));
 await page.setViewportSize({width:360,height:400});await page.locator('#welcomeConfirm').scrollIntoViewIfNeeded();
 assert(await page.locator('#welcomeConfirm').evaluate(e=>e.getBoundingClientRect().bottom<=innerHeight));
 await page.locator('#welcomeConfirm').click();await page.waitForFunction(()=>nativeLayouts.at(-1).visible===true);
 assert.equal(await page.locator('#employeeLoginId').inputValue(),'admin');assert.equal(await page.locator('#pin').evaluate(e=>e===document.activeElement),true);
 assert.deepEqual(errors,[]);await browser.close();console.log('Chromium 320/360/412px: no clipped heading/terms, short viewport scrolling, native input hidden during welcome and restored after confirmation.');
})().catch(e=>{console.error(e);process.exit(1)});
