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
 await page.route('https://fixture.test/**',r=>r.fulfill({body:'<html><body><main class="shell"><header class="top"></header><div id="staffRooms"></div><span id="staffCount"></span><div id="detail" hidden></div><div id="composeOverlay" hidden></div></main></body></html>',contentType:'text/html'}));await page.goto('https://fixture.test/messages.html#bot');
 await page.addStyleTag({content:fs.readFileSync('message-hub.css','utf8')});await page.evaluate(()=>{
  window.GuestSupport={esc:v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};window.StaffChat={contractId:()=>null,cleanText:s=>s};window.OMSBotAvatar={src:'',upgrade:async()=>''};window.OMG_SUPABASE={url:'https://api.fixture.test',publishableKey:'public'};
  window.session={sessionKind:'owner',propertyId:'home',accessToken:'fixture'};window.requests=[];window.item={message_id:'notice',property_id:'home',sender_type:'system',message_type:'general',message:'[자동메시지 발송실패]\n서울네스트 · 객실 203\n예약 #203\n예약사이트: Booking.com\n게스트: Guest C\n메시지: 체크인 안내\n사유: 비밀번호 누락. 객실 연결을 확인해주세요.\n문제 해결 후 이 실패 건만 재전송해주세요.',created_at:'2026-11-25T00:00:00Z',auto_message:{arrival:'2026-11-25',departure:'2026-11-28',delivery_id:'deliveryC',retry_count:1,status:'failed',can_retry:true}};
  window.omgSupabase={rpc:async name=>({data:name==='notification_bot_settings'?{ok:true,bots:[{property_id:'home',display_name:'OMS 알림'}]}:{ok:true,messages:[item],unread_by_property:{}}})};
  window.fetch=async(u,o)=>{requests.push(JSON.parse(o.body));item.auto_message.can_retry=false;item.auto_message.status='waiting';return {ok:true,json:async()=>({ok:true,retry_queued:1})};};
 });
 for(const f of ['auto-message-retry.js','notification-bot.js'])await page.addScriptTag({content:fs.readFileSync(f,'utf8')});
 await page.addStyleTag({content:'*{box-sizing:border-box}html,body{overflow-x:hidden}body{margin:0;font-family:Arial,sans-serif}#detail{position:fixed;inset:20px;z-index:1000;background:white;padding:20px;white-space:pre-wrap}'});
 await page.evaluate(()=>NotificationBot.init(session,{openDetail:i=>{const h=document.getElementById('detail');h.hidden=false;h.textContent=i.message;OMSAutoMessageRetry.mount(h,i,session);},compose:()=>{}}));
 await page.getByRole('button',{name:'상세보기'}).waitFor();
 assert.deepEqual(await page.locator('.bot-failure-summary p').allTextContents(),['서울네스트 · 203 · Guest C · 11.25~11.28','비밀번호 누락.']);
 assert.equal(await page.locator('#botTimeline .auto-retry-actions').count(),0,'retry instructions only appear in details');
 async function inlineDetails(){
  assert.equal(await page.locator('.bot-failure-notice .bot-notice-footer').count(),0);
  assert(await page.locator('.bot-failure-reason').evaluate(e=>{const p=e.querySelector('p').getBoundingClientRect(),b=e.querySelector('button').getBoundingClientRect();return Math.abs((p.top+p.bottom-b.top-b.bottom)/2)<1&&b.left>=p.right&&b.height<24;}),'details stays on the second line');
  assert(await page.locator('.bot-failure-notice').evaluate(e=>e.getBoundingClientRect().height<100),'compact card height');
 }

 for(const width of [320,390,760]){await page.setViewportSize({width,height:900});assert(await page.locator('.bot-failure-summary p').evaluateAll(els=>els.every(e=>e.getBoundingClientRect().height<24)),'exactly two summary lines');await inlineDetails();}
 await page.getByRole('button',{name:'상세보기'}).click();assert.match(await page.locator('#detail').textContent(),/예약사이트: Booking.com[\s\S]*문제 해결 후 이 실패 건만 재전송해주세요/);
 await page.getByRole('button',{name:'이 게스트에게 재전송'}).waitFor();
 await page.screenshot({path:'/tmp/auto-retry-bot.png'});await page.getByRole('button',{name:'이 게스트에게 재전송'}).click();await page.waitForFunction(()=>requests.length===1);assert.deepEqual(await page.evaluate(()=>requests[0].data),{property_id:'home',notice_id:'notice'});assert(await page.getByRole('button',{name:'이 게스트에게 재전송'}).isDisabled());assert.equal(await page.getByRole('link',{name:'발송 기록'}).getAttribute('href'),'guest-auto-messages.html?property=home&logs=1');assert.deepEqual(errors,[]);
 await page.evaluate(()=>{const h=document.createElement('div');document.body.append(h);OMSAutoMessageRetry.mount(h,item,{sessionKind:'staff'});if(h.children.length)throw Error('staff can retry');});
 await page.evaluate(()=>{document.getElementById('detail').hidden=true;item.message=item.message.replace('[자동메시지 발송실패]','[자동메시지 미발송]');item.auto_message.status='skipped';item.auto_message.can_retry=false;NotificationBot.update({messages:[item]});});
 assert.equal(await page.locator('.bot-failure-dates').textContent(),' · 11.25~11.28');
 for(const width of [320,390,760]){await page.setViewportSize({width,height:900});await inlineDetails();await page.screenshot({path:'/tmp/auto-message-missed-inline-'+width+'.png'});}
 await page.evaluate(()=>{item.auto_message.arrival=null;item.auto_message.departure=null;NotificationBot.update({messages:[item]});});
 assert.equal(await page.locator('.bot-failure-dates').textContent(),' · 미정~미정','missing stay dates are not guessed from scheduled send time');
 await page.addStyleTag({content:fs.readFileSync('auto-message-actions.css','utf8')});
 await page.evaluate(()=>{item.auto_message.followup='open';item.auto_message.status='failed';item.message=item.message.replace('[자동메시지 미발송]','[자동메시지 발송실패]');NotificationBot.update({messages:[item]});});
 await page.setViewportSize({width:320,height:900});await page.locator('.auto-followup-actions summary').click();
 assert.equal(await page.locator('.auto-followup-choices button').count(),3);assert(await page.locator('.auto-followup-actions').evaluate(e=>e.scrollWidth<=e.clientWidth));await page.screenshot({path:'/tmp/auto-message-followup-bot.png'});
 await page.evaluate(()=>{document.getElementById('detail').hidden=true;delete item.auto_message;item.message='[IOT 도어락 처리 실패]\n서울네스트 · 객실 401\n게스트: Guest <img src=x>\n예약 #401\n숙박: 2026-11-27 ~ 2026-11-29\n기존 Lock info가 있어 비밀번호를 생성하지 못했습니다. 기존 Lock info를 삭제한 뒤 다시 시도해 주십시오.\nProperty > IOT 도어락 연동에서 해당 예약을 확인하고 재시도해주세요.';NotificationBot.update({messages:[item]});});
 assert.deepEqual(await page.locator('.bot-failure-summary p').allTextContents(),['서울네스트 · 401 · Guest <img src=x> · 11.27~11.29','기존 비밀번호가 있어 새 비밀번호 설정 실패']);
 assert.equal(await page.locator('.bot-failure-summary img').count(),0,'guest text is escaped');
 for(const width of [320,390,760]){await page.setViewportSize({width,height:900});assert(await page.locator('.bot-failure-summary p').evaluateAll(els=>els.every(e=>e.getBoundingClientRect().height<24)));assert(await page.locator('.bot-failure-dates').evaluate(e=>e.scrollWidth<=e.clientWidth),'stay dates remain visible even with a long name');assert(await page.locator('.bot-failure-notice').evaluate(e=>e.getBoundingClientRect().right<=document.documentElement.clientWidth));assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await inlineDetails();await page.screenshot({path:'/tmp/auto-message-lock-summary-'+width+'.png'});}
 await page.getByRole('button',{name:'상세보기'}).click();assert.match(await page.locator('#detail').textContent(),/숙박: 2026-11-27 ~ 2026-11-29[\s\S]*기존 Lock info를 삭제한 뒤/);
 await page.evaluate(()=>{document.getElementById('detail').hidden=true;item.message='[IOT 도어락 처리 실패]\n알 수 없는 형식은 원문 유지';NotificationBot.update({messages:[item]});});
 assert.equal(await page.locator('.bot-failure-summary').count(),0);assert.match(await page.locator('#botTimeline').textContent(),/알 수 없는 형식은 원문 유지/);
 await page.close();
 console.log('Retry UI: 320/390/760px, guest identity, select two failed guests, retry only remaining failure, bot exact-notice action and staff exclusion passed');
 }finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1)});
