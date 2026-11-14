const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const read=f=>fs.readFileSync(f,'utf8');
(async()=>{const browser=await chromium.launch({headless:true});try{
 const page=await browser.newPage({viewport:{width:360,height:850}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{
  const changed=sessionStorage.getItem('fixture-account')==='other';
  const session={sessionId:changed?'login-b':'login-a',sessionKind:'owner',ownerId:changed?'owner-b':'owner-a',propertyId:'property-a',accessToken:'fixture',timezone:'Asia/Seoul'};
  window.omgSession={require:async()=>session,get:()=>session,logout:async()=>{}};
  window.omgWorkConfig={load:async()=>({can_manage:true,property:{management_number:1,name:'테스트 지점'}})};
  window.omgPropertySelector={mount:()=>new Promise(()=>{})}; // Slow optional picker must not hold up summaries.
  window.OMGNative={};window.HomeMessageQueue={update(){},add(){}};window.rpcCalls=[];window.pending=[];
  const value=name=>{
   const updated=sessionStorage.getItem('fixture-updated')==='yes';
   if(name==='list_property_messages')return{ok:true,can_manage:true,unread_count:2,messages:[]};
   if(name==='work_report_inbox')return{ok:true,unread_count:updated?0:1,reports:[]};
   if(name==='list_property_shares')return{ok:true,properties:[{property_id:'property-a',is_own:true}]};
   if(name==='list_shared_missions')return{ok:true,missions:updated?[]:[{id:'task-a',title:'오늘 업무 <img src=x>',timing:'today',active:true,target_count:1,completed_count:0}]};
   if(name==='calendar_event_action')return{ok:true,events:[]};
   if(name==='guest_message_unread')return{ok:true,unread:updated?0:1,messenger_unread:2};
   throw Error('Unexpected RPC '+name);
  };
  const request=name=>{rpcCalls.push(name);if(name==='is_platform_administrator')return Promise.resolve({data:false});const finish=()=>name==='guest'?value(name):{data:value(name)};if(sessionStorage.getItem('fixture-hold')==='yes')return new Promise((resolve,reject)=>pending.push({name,resolve:()=>resolve(finish()),reject}));return Promise.resolve(finish());};
  window.omgSupabase={rpc:request};window.GuestSupport={call:()=>request('guest')};
  window.readySnapshot=null;
  new MutationObserver(()=>{if(!readySnapshot&&document.querySelector('#appShell.ready'))window.readySnapshot={message:document.querySelector('#messageCounter').textContent,display:document.querySelector('#messageCounter').style.display,mission:document.querySelector('#todayMissionCount').textContent,today:document.querySelector('#todayOverviewItems').textContent};}).observe(document,{subtree:true,attributes:true,attributeFilter:['class']});
 });
 const allowed=new Set(['page-transition.js','worker-tasks.js','home-guest-count.js','home-summary-state.js']);
 const html=read('app.html').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(_,url)=>allowed.has(url.split('?')[0])?'<script>'+read(url.split('?')[0])+'</script>':'');
 await page.route('**/*',route=>{const file=new URL(route.request().url()).pathname.slice(1);if(file==='app.html')return route.fulfill({contentType:'text/html',body:html});if(file==='away.html')return route.fulfill({contentType:'text/html',body:'<p>세부 메뉴</p>'});if(!file.includes('..')&&fs.existsSync(file)&&fs.statSync(file).isFile())return route.fulfill({path:file});return route.fulfill({status:204,body:''});});
 const home='https://omgworks24.com/app.html';
 await page.goto(home);await page.waitForFunction(()=>document.querySelector('#messageCounter').textContent==='3'&&document.querySelector('.today-overview-item'));
 assert.equal(await page.locator('#todayMissionCount').textContent(),'1');assert.equal(await page.locator('#todayOverviewItems img').count(),0);
 assert(await page.evaluate(()=>rpcCalls.indexOf('calendar_event_action')<rpcCalls.indexOf('list_shared_missions')),'calendar and missions start concurrently');
 await page.evaluate(()=>sessionStorage.setItem('fixture-hold','yes'));await page.goto('https://omgworks24.com/away.html');await page.goto(home);await page.waitForFunction(()=>readySnapshot);
 let ready=await page.evaluate(()=>readySnapshot);assert.equal(ready.message,'3');assert.equal(ready.display,'grid');assert.equal(ready.mission,'1');assert(ready.today.includes('오늘 업무'),'snapshot must be visible on the first revealed frame');
 await page.evaluate(()=>{for(let i=0;i<4;i++){dispatchEvent(new Event('focus'));document.dispatchEvent(new Event('visibilitychange'));dispatchEvent(new Event('pageshow'));}});
 assert.equal(await page.evaluate(()=>rpcCalls.filter(x=>x==='list_property_messages').length),1);
 assert.equal(await page.evaluate(()=>rpcCalls.filter(x=>x==='calendar_event_action').length),1);
 await page.evaluate(()=>sessionStorage.setItem('fixture-updated','yes'));
 for(let i=0;i<4;i++){await page.evaluate(()=>pending.splice(0).forEach(p=>p.resolve()));await page.waitForTimeout(30);}
 await page.waitForFunction(()=>document.querySelector('#messageCounter').textContent==='2'&&document.querySelector('#todayMissionCount').textContent==='0'&&document.querySelector('#todayOverviewItems').textContent.includes('없습니다'));
 await page.screenshot({path:'/tmp/oms-home-summary-updated.png'});
 await page.reload();await page.waitForFunction(()=>readySnapshot);ready=await page.evaluate(()=>readySnapshot);assert.equal(ready.message,'2');assert.equal(ready.mission,'0');
 await page.evaluate(()=>pending.splice(0).forEach(p=>p.reject(Error('offline'))));await page.waitForTimeout(50);assert.equal(await page.locator('#messageCounter').textContent(),'2');assert.equal(await page.locator('#todayMissionCount').textContent(),'0');
 await page.evaluate(()=>sessionStorage.setItem('fixture-account','other'));await page.reload();await page.waitForFunction(()=>readySnapshot);ready=await page.evaluate(()=>readySnapshot);assert.equal(ready.mission,'—');assert(ready.today.includes('불러오는 중'));assert.notEqual(ready.display,'grid');
 assert.deepEqual(errors,[]);console.log('PASS actual Home: immediate cached first frame after submenu, independent requests, unchanged values on network failure, zero updates, event deduplication and account isolation');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
