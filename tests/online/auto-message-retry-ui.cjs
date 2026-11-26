const {chromium}=require('playwright'),fs=require('fs'),assert=require('node:assert/strict');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
(async()=>{const browser=await chromium.launch({headless:true});try{for(const width of [320,390,760]){
 const page=await browser.newPage({viewport:{width,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(({ids})=>{
  window.omgSession={require:async()=>({sessionKind:'owner',propertyId:'home',accessToken:'fixture'})};window.OMG_SUPABASE={url:'https://fixture.test',publishableKey:'public'};
  window.requests=[];window.logs=ids.map((id,i)=>({id,booking_id:i+201,guest_name:['Guest A','Guest B','Guest C'][i],room_name:String(i+201),arrival:'2026-11-25',departure:'2026-11-28',title:'체크인 안내',status:i?'failed':'sent',late_booking:!i,channel:i?'Agoda':'Booking.com',can_retry:!!i,retry_count:0,error:i?'비밀번호 누락':null,updated_at:'2026-11-25T00:00:00Z'}));
  window.fetch=async(u,o)=>{const b=JSON.parse(o.body);requests.push(b);let queued=0;if(b.action==='auto_message_retry'){for(const t of b.data.targets){const l=logs.find(x=>x.id===t.id);if(l?.status==='failed'&&l.retry_count===t.retry_count){l.status='waiting';l.can_retry=false;l.retry_count++;queued++;}}}return {ok:true,json:async()=>({ok:true,property_id:'home',branches:[{id:'home',name:'One Minute'}],rules:[],logs:structuredClone(logs),retry_queued:queued})};};
 },{ids:[id(1),id(2),id(3)]});
 const keep=new Set(['guest-auto-messages.js','property-selector.js']);const html=fs.readFileSync('guest-auto-messages.html','utf8').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(all,url)=>keep.has(url.split('?')[0])?all:'');
 await page.route('**/*',r=>{const f=new URL(r.request().url()).pathname.slice(1);if(f==='guest-auto-messages.html')return r.fulfill({body:html,contentType:'text/html'});if(!f.includes('..')&&fs.existsSync(f)&&fs.statSync(f).isFile())return r.fulfill({path:f});return r.fulfill({status:204,body:''});});
 await page.goto('https://omgworks24.com/guest-auto-messages.html?logs=1');await page.waitForSelector('[data-retry-select]');
 assert.equal(await page.locator('.auto-log').count(),3);assert.match(await page.locator('.auto-log').first().textContent(),/예외 발송 완료/);assert.match(await page.locator('.auto-log').nth(1).textContent(),/Agoda/);assert.equal(await page.locator('[data-retry]').count(),2);assert.equal(await page.locator('[data-retry-select]').count(),2);
 await page.locator('[data-retry-select]').nth(0).check();await page.locator('[data-retry-select]').nth(1).check();await page.getByRole('button',{name:'선택 2명 재전송'}).click();
 await page.waitForFunction(()=>requests.some(x=>x.action==='auto_message_retry'));let sent=await page.evaluate(()=>requests.find(x=>x.action==='auto_message_retry').data.targets);assert.deepEqual(sent,[{id:id(2),retry_count:0},{id:id(3),retry_count:0}]);
 await page.evaluate(()=>{logs[1].status='sent';logs[2].status='failed';logs[2].can_retry=true;});await page.locator('#refreshAutoLogs').click();await page.waitForSelector('[data-retry]');assert.equal(await page.locator('[data-retry]').count(),1);assert.match(await page.locator('.auto-log').filter({has:page.locator('[data-retry]')}).textContent(),/Guest C/);
 await page.screenshot({path:'/tmp/auto-retry-history-'+width+'.png',fullPage:true});await page.locator('[data-retry]').click();await page.waitForFunction(()=>requests.filter(x=>x.action==='auto_message_retry').length===2);assert.deepEqual(await page.evaluate(()=>requests.filter(x=>x.action==='auto_message_retry')[1].data.targets),[{id:id(3),retry_count:1}]);
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));assert.deepEqual(errors,[]);await page.close();
 }
 // The actual bot feed mounts its button from authenticated structured metadata, not text parsing.
 const page=await browser.newPage({viewport:{width:390,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://fixture.test/**',r=>r.fulfill({body:'<html><body><header class="top"></header><div id="staffRooms"></div><span id="staffCount"></span><div id="detail" hidden></div><div id="composeOverlay" hidden></div></body></html>',contentType:'text/html'}));await page.goto('https://fixture.test/messages.html#bot');
 await page.addStyleTag({content:fs.readFileSync('message-hub.css','utf8')});await page.evaluate(()=>{
  window.GuestSupport={esc:v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};window.StaffChat={contractId:()=>null,cleanText:s=>s};window.OMSBotAvatar={src:'',upgrade:async()=>''};window.OMG_SUPABASE={url:'https://api.fixture.test',publishableKey:'public'};
  window.session={sessionKind:'owner',propertyId:'home',accessToken:'fixture'};window.requests=[];window.item={message_id:'notice',property_id:'home',sender_type:'system',message_type:'general',message:'[자동메시지 발송실패]\n게스트: Guest C\n예약 #203\n사유: 비밀번호 누락',created_at:'2026-11-25T00:00:00Z',auto_message:{delivery_id:'deliveryC',retry_count:1,status:'failed',can_retry:true}};
  window.omgSupabase={rpc:async name=>({data:name==='notification_bot_settings'?{ok:true,bots:[{property_id:'home',display_name:'OMS 알림'}]}:{ok:true,messages:[item],unread_by_property:{}}})};
  window.fetch=async(u,o)=>{requests.push(JSON.parse(o.body));item.auto_message.can_retry=false;item.auto_message.status='waiting';return {ok:true,json:async()=>({ok:true,retry_queued:1})};};
 });
 for(const f of ['auto-message-retry.js','notification-bot.js'])await page.addScriptTag({content:fs.readFileSync(f,'utf8')});
 await page.evaluate(()=>NotificationBot.init(session,{openDetail:()=>{},compose:()=>{}}));await page.getByRole('button',{name:'이 게스트에게 재전송'}).waitFor();
 await page.screenshot({path:'/tmp/auto-retry-bot.png'});await page.getByRole('button',{name:'이 게스트에게 재전송'}).click();await page.waitForFunction(()=>requests.length===1);assert.deepEqual(await page.evaluate(()=>requests[0].data),{property_id:'home',notice_id:'notice'});assert(await page.getByRole('button',{name:'이 게스트에게 재전송'}).isDisabled());assert.equal(await page.getByRole('link',{name:'발송 기록'}).getAttribute('href'),'guest-auto-messages.html?property=home&logs=1');assert.deepEqual(errors,[]);
 await page.evaluate(()=>{const h=document.createElement('div');document.body.append(h);OMSAutoMessageRetry.mount(h,item,{sessionKind:'staff'});if(h.children.length)throw Error('staff can retry');});await page.close();
 console.log('Retry UI: 320/390/760px, guest identity, select two failed guests, retry only remaining failure, bot exact-notice action and staff exclusion passed');
 }finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1)});
