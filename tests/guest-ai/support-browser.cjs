const {chromium}=require('playwright');
const fs=require('node:fs'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({...(process.env.OMS_CHROMIUM_PATH?{executablePath:process.env.OMS_CHROMIUM_PATH}:{}),headless:true});
 const room='11111111-1111-4111-8111-111111111111';
 try{for(const width of [320,390,760]){
 const page=await browser.newPage({viewport:{width,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://fixture.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><div class="top"></div><div id="staffRooms"></div><span id="staffCount"></span><div id="detail" hidden></div><div id="composeOverlay" hidden></div>'}));
 await page.goto('https://fixture.test/messages.html');
 for(const file of ['guest-support.css','message-hub.css'])await page.addStyleTag({content:fs.readFileSync(file,'utf8')});
 await page.evaluate(({room,portrait})=>{
  window.GuestSupport={esc:s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
  window.StaffChat={contractId:s=>s.startsWith('[CONTRACT]')?'fixture-contract':null,cleanText:s=>s};window.OMSBotAvatar={upgrade:async()=>portrait};
  window.__details=[];window.__unsafe=false;
  const base={property_id:'p',sender_type:'system',message_type:'general',read_at:'2026-11-12T02:25:00Z'};
  window.__items=[
   {message_id:'ai',guest_chat_room_id:room,message:'[OMS-GUEST-CHAT:'+room+']\n긴급 AI 지원요청\n게스트명 · 객실 미정\n게스트 문의가 왔습니다. 직원 확인이 필요합니다.\n시설 고장 비상 확인 필요\n객실에 불이 난 것 같습니다'},
   {message_id:'holiday',message_type:'holiday_notice',approval_status:'approved',message:'결재완료 - 휴일신청\n날짜: 2026-11-15\n신청자: 테스트 직원\n대상: 테스트 직원\n휴일 신청 사유: 개인 일정\n두 번째 줄도 유지'},
   {message_id:'system',is_platform_system_notice:true,message:'[시스템] 새로운 안내\n<img src=x onerror="__unsafe=true">'},
   {message_id:'attendance',message_type:'attendance_approval',approval_status:'pending',message:'출퇴근 시간 수정 요청\n근무일: 2026-11-11\n기존: 2026-11-11 09:00 ~ -\n요청: 2026-11-11 09:00 ~ 2026-11-11 18:00'},
   {message_id:'share',message_type:'property_share_approval',approval_status:'pending',message:'Property 공유 요청\n요청 지점: 테스트 지점 (Property ID 2)\n요청 항목: 근태, 메세지'},
   {message_id:'notice',message_type:'announcement',message:'청소 후 비품 재고를 확인해주세요.'},
   {message_id:'contract',message:'[CONTRACT] 근로계약서를 확인해주세요.'},
   {message_id:'fallback',message_type:'holiday_notice',message:'기존 형식이 아닌 알림도 내용 전체를 유지합니다. '+('긴문장'.repeat(45))},
   {message_id:'booking',message:'[OMS-BOOKING:8123]\n당일 예약 접수\n예약 게스트 · 401호\n2026-11-12 → 2026-11-14 · Booking.com'},
   {message_id:'ai-regular',guest_chat_room_id:room,message:'[OMS-GUEST-CHAT:'+room+']\nAI 메시지 지원요청\n게스트명 · 401호\n게스트 문의가 왔습니다. 직원 확인이 필요합니다.\n직원 확인 필요\n숙박을 하루 더 연장할 수 있나요?'}
  ].map((item,n)=>({...base,...item,created_at:'2026-11-12T02:24:'+String(n).padStart(2,'0')+'Z'}));
  window.omgSupabase={rpc:async(name)=>({data:name==='notification_bot_settings'?{ok:true,bots:[{property_id:'p',display_name:'매니저',property_name:'One Minute'}]}:{ok:true,unread_by_property:{},messages:__items}})};
 },{room,portrait:'data:image/webp;base64,'+fs.readFileSync('bot-avatar-helper.webp').toString('base64')});
 await page.addScriptTag({content:fs.readFileSync('notification-bot.js','utf8')});
 await page.evaluate(()=>NotificationBot.init({propertyId:'p',accessToken:'fixture',sessionKind:'staff'},{refresh:async()=>{},openDetail:i=>__details.push(i.message_id),compose:()=>{}}));
 await page.locator('.bot-room').click();await page.locator('[data-bot-row="ai"] .bot-notice').waitFor();
 assert.equal(await page.locator('.bot-notice').count(),9,'all categories share the same card');
 assert.equal(await page.locator('.bot-notice-footer .bot-chat-action').count(),9,'all actions use compact footer');
 assert((await page.locator('.bot-chat-action').evaluateAll(xs=>xs.map(x=>({bg:getComputedStyle(x).backgroundColor,width:x.getBoundingClientRect().width,card:x.closest('.bot-notice').getBoundingClientRect().width})))).every(x=>x.bg==='rgba(0, 0, 0, 0)'&&x.width<x.card*.6),'text actions are transparent and compact');
 const ai=page.locator('[data-bot-row="ai"]');assert(await ai.locator('.is-urgent').count());assert.equal(await ai.locator('.bot-notice-quote p').innerText(),'객실에 불이 난 것 같습니다');assert.equal(await ai.locator('.bot-notice-context').innerText(),'게스트명 · 객실 미정');
 assert(!(await ai.innerText()).includes('시설 고장 비상 확인 필요'));assert(!(await page.locator('#botTimeline').innerText()).includes('OMS-GUEST-CHAT:'));
 const holiday=page.locator('[data-bot-row="holiday"]');assert.equal(await holiday.locator('dt').allTextContents().then(x=>x.join('|')),'날짜|신청자·대상|사유');assert((await holiday.innerText()).includes('두 번째 줄도 유지'));assert(!(await holiday.innerText()).includes('결재완료 - 휴일신청'));assert((await holiday.innerText()).includes('승인 완료'));
 assert.equal(await page.locator('[data-bot-row="system"] .bot-notice-body img').count(),0);assert.equal(await page.evaluate(()=>__unsafe),false);
 assert.equal(await page.locator('[data-bot-row="attendance"] dd').count(),3);assert.equal(await page.locator('[data-bot-row="share"] dd').count(),2);
 assert((await page.locator('[data-bot-row="fallback"] .bot-notice-body').innerText()).includes('긴문장'.repeat(45)));
 assert((await page.locator('.bot-notice-body p,.bot-notice-fields dd').evaluateAll(xs=>xs.map(x=>getComputedStyle(x).fontWeight))).every(w=>w==='400'));
 assert(await page.locator('#botTimeline').evaluate(el=>el.scrollWidth<=el.clientWidth),'no horizontal clipping');
 for(const id of ['holiday','system','attendance','share','notice','contract'])await page.locator('[data-bot-message="'+id+'"]').click();assert.deepEqual(await page.evaluate(()=>__details),['holiday','system','attendance','share','notice','contract']);
 const booking=page.locator('[data-bot-row="booking"]');assert.equal(await booking.locator('.is-urgent').count(),0);assert.equal(await booking.locator('.bot-notice-badge').innerText(),'당일 예약 접수');assert(!(await booking.innerText()).includes('OMS-BOOKING'));await booking.getByRole('button',{name:'내용 확인'}).click();assert.equal(await page.evaluate(()=>__details.at(-1)),'booking');
 // Opening cards retains their existing action and does not acknowledge approval/notice content.
 assert.equal(await page.locator('[data-bot-row="notice"] .bot-state').innerText(),'확인 필요');
 await page.locator('#botTimeline').evaluate(el=>el.scrollTop=0);await page.screenshot({path:'/tmp/oms-ai-support-mobile-'+width+'.png'});
 await page.locator('[data-bot-row="system"]').scrollIntoViewIfNeeded();await page.screenshot({path:'/tmp/oms-ai-support-types-'+width+'.png'});
 await ai.getByRole('button',{name:'게스트 대화 열기'}).click();await page.waitForURL('https://fixture.test/guest-chat.html?room='+room);
 assert.deepEqual(errors,[]);await page.close();console.log('PASS '+width+'px: all bot categories, deduplication, regular font, safe text, detail actions and guest routing');
 }}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
