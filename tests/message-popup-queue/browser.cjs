const {chromium}=require('playwright'),fs=require('fs'),assert=require('node:assert/strict');
(async()=>{const browser=await chromium.launch({headless:true});try{
const page=await browser.newPage({viewport:{width:360,height:740}});
const html=fs.readFileSync('app.html','utf8').replace(/<script[\s\S]*?<\/script>/g,'').replace(/<link[^>]*>/g,'').replace(/omg-booting/g,'');
await page.route('https://queue.test/**',r=>r.fulfill({contentType:'text/html',body:html}));await page.goto('https://queue.test/app.html');
await page.addStyleTag({path:'home-message-queue.css'});await page.addScriptTag({path:'home-message-queue.js'});
await page.evaluate(()=>{window.receipts=[];window.failReads=true;window.omgSupabase={rpc:async(n,a)=>{receipts.push(a.p_message_id);return failReads?{error:'offline'}:{data:{ok:true}}}};window.items=Array.from({length:4},(_,n)=>({message_id:'m'+n,sender_label:n%2?'일정 알림':'To do 알림',message:'지연: 냉장고 점검 '+(n+1),created_at:String(n)}));HomeMessageQueue.update(items,'synthetic',false)});
await page.screenshot({path:'/tmp/oms-popup-queue.png'});
for(let n=0;n<4;n++){assert.equal(await page.locator('.message-arrival-count').textContent(),`남은 알림 ${4-n}건`);assert.equal(await page.locator('#messageArrivalBody').textContent(),'지연: 냉장고 점검 '+(n+1));const b=await page.locator('.message-arrival-confirm').boundingBox();assert(b.y>=0&&b.y+b.height<=740&&b.x>=0&&b.x+b.width<=360);await page.locator('.message-arrival-confirm').click();await page.waitForTimeout(220);}
assert.equal(await page.locator('#messageArrival').isVisible(),false);
await page.evaluate(()=>{failReads=false;HomeMessageQueue.update(items,'synthetic',true)});await page.waitForTimeout(100);
assert.deepEqual(await page.evaluate(()=>JSON.parse(sessionStorage.getItem('oms-popup-pending:synthetic'))),[]);
assert.equal(await page.locator('#messageArrival').isVisible(),false);
console.log('PASS Chromium 360px: four real clicks, button in viewport, offline read receipts retry without duplicate popups');
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
