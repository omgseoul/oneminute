const {chromium}=require('playwright'),fs=require('fs'),assert=require('node:assert/strict');
(async()=>{const browser=await chromium.launch({headless:true,args:['--no-sandbox']});const page=await browser.newPage({viewport:{width:360,height:740}});
await page.setContent('<!doctype html><meta name="viewport" content="width=device-width"><body style="background:#f4f7fc;font-family:sans-serif">OMS</body>');
await page.evaluate(()=>{
 window.responses=[];window.calls=[];window.fail=false;window.s={sessionKind:'staff',accessToken:'test-token'};
 window.omgSession={get:()=>s,set:v=>{s=v},fromResponse:(v,t)=>({...v,accessToken:t})};
 window.omgSupabase={rpc:async(n,args)=>{calls.push(args);if(fail)throw new Error('연결을 확인해주세요.');return {data:responses.shift()}}};
 window.result=()=>({ok:true,server_now:new Date().toISOString(),session:{sessionKind:'staff',status:'working'},pending:{id:'request-one',deadline_at:new Date(Date.now()+600000).toISOString()}});
 responses.push(result());
});
await page.addStyleTag({content:fs.readFileSync('work-shift-confirmation.css','utf8')});await page.addScriptTag({content:fs.readFileSync('work-shift-confirmation.js','utf8')});
const button=page.getByRole('button',{name:'예, 계속 근무중입니다.',exact:true});await button.waitFor();assert.equal(await page.locator('dialog button').count(),1);await page.keyboard.press('Escape');assert.equal(await page.locator('dialog[open]').count(),1);
await page.evaluate(()=>fail=true);await button.click();await page.getByRole('status').filter({hasText:'연결을 확인해주세요.'}).waitFor();assert(await button.isEnabled());
await page.evaluate(()=>{fail=false;responses.push({...result(),pending:null,confirmed:true})});await button.click();await page.waitForFunction(()=>!document.querySelector('dialog'));assert.equal(await page.evaluate(()=>s.accessToken),'test-token');
await page.evaluate(()=>{responses.push(result());return OMSWorkShiftConfirmation.check()});await button.waitFor();const bounds=await page.locator('dialog').boundingBox();assert(bounds.x>=0&&bounds.x+bounds.width<=360&&bounds.y>=0&&bounds.y+bounds.height<=740);await page.screenshot({path:'/tmp/oms-shift/work-confirmation-mobile.png'});
await page.evaluate(()=>{responses.push({...result(),pending:null,session:{sessionKind:'staff',status:'completed',unconfirmedEndedAt:new Date().toISOString()}});return OMSWorkShiftConfirmation.check()});assert.equal(await page.locator('dialog').count(),0);assert.equal(await page.evaluate(()=>s.accessToken),'test-token');assert.equal(await page.evaluate(()=>calls.filter(c=>c.p_confirmation_id).length),2);
await page.evaluate(()=>{s={sessionKind:'owner',accessToken:'owner'};return OMSWorkShiftConfirmation.check()});assert.equal(await page.locator('dialog').count(),0);
console.log('PASS web popup: explicit response, retry, timeout, login retention, owner exclusion, 360px layout');await browser.close();})().catch(e=>{console.error(e);process.exitCode=1});
