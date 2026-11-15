const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom'),{chromium}=require('playwright');
const html='<html><head></head><body><header class="top"></header><div id="staffRooms"></div><span id="staffCount"></span><div id="detail" hidden></div></body></html>';
function fixture(){
 window.GuestSupport={esc:v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};window.StaffChat={contractId:()=>null,cleanText:s=>s};window.OMSBotAvatar={src:'bot-avatar-helper.webp',upgrade:async v=>v};window.__calls=[];
 const guest='Synthetic <img src=x>',context={kind:'online',guest,room:'404',arrival:'2026-11-14',departure:'2026-11-18',property:'One Minute',channel:'Booking.com',sent:'11.14 11:33'};
 window.__items=[{message_id:'online',property_id:'home',sender_type:'system',message_type:'general',message:'[OMS-ONLINE:123]\n'+guest+'\nHello, is there a lobby?',guest_context:context,created_at:'2026-11-14T02:33:00Z',read_at:'2026-11-14T02:34:00Z'},{message_id:'legacy',property_id:'home',sender_type:'system',message_type:'general',message:'[OMS-ONLINE:124]\nOlder guest\nOriginal message',created_at:'2026-11-14T02:35:00Z',read_at:'2026-11-14T02:36:00Z'}];
 window.omgSupabase={rpc:async(name,args)=>{window.__calls.push({name,args});return {data:name==='notification_bot_settings'?{ok:true,bots:[{property_id:'home',property_name:'One Minute',display_name:'매니저'}]}:{ok:true,messages:__items,unread_by_property:{}}};}};
 window.start=()=>NotificationBot.init({sessionKind:'owner',propertyId:'home',accessToken:'fixture'},{refresh:async()=>{},openDetail:()=>{},openAnnouncement:()=>{}});
}
const scripts=['guest-message-card.js','notification-bot.js'],tick=()=>new Promise(r=>setTimeout(r,50));
(async()=>{
 const w=new JSDOM(html,{url:'https://omgworks24.com/messages.html#bot',runScripts:'outside-only',pretendToBeVisual:true}).window;w.eval('('+fixture.toString()+')()');w.__items.push({message_id:'booking',property_id:'home',sender_type:'system',message_type:'general',message:'[OMS-BOOKING:321]\n당일 예약 접수\nSynthetic guest · 401호\n11.15 → 11.16 · Booking.com',created_at:'2026-11-14T02:37:00Z'});w.__items.push({message_id:'urgent',property_id:'home',sender_type:'system',message_type:'general',message:'AI 메시지 지원요청\\n직원 확인이 필요합니다.',guest_chat_room_id:'00000000-0000-0000-0000-000000000001',created_at:'2026-11-14T02:36:00Z'});for(const f of scripts)w.eval(fs.readFileSync(f,'utf8'));w.start();await tick();assert.equal(w.document.querySelector('#botConversation').hidden,false,'Booking push hash automatically opens BOT room');assert(w.document.querySelector('[data-bot-row=booking]').textContent.includes('당일 예약 알림'));assert(w.document.querySelector('[data-bot-row=booking]').textContent.includes('예약 상세'));assert.equal(w.document.querySelector('.bot-online-notice'),null);assert(!w.document.body.textContent.includes('Older guest'));assert(w.document.body.textContent.includes('직원 확인'));w.document.querySelector('#botConversation').hidden=true;w.dispatchEvent(new w.Event('omg:open-bot'));assert.equal(w.document.querySelector('#botConversation').hidden,false,'Repeat notification tap reopens existing BOT page');w.close();console.log('Bot inbox: ordinary guest arrival cards removed, AI staff assistance retained');

 const browser=await chromium.launch({headless:true});
 try{for(const width of [320,390,760]){
  const page=await browser.newPage({viewport:{width,height:900}});
  await page.route('https://fixture.test/**',r=>r.fulfill({contentType:'text/html',body:html}));
  await page.goto('https://fixture.test/messages.html#bot');
  for(const file of ['guest-support.css','message-hub.css'])await page.addStyleTag({content:fs.readFileSync(file,'utf8')});
  await page.evaluate(fixture);
  await page.evaluate(src=>{OMSBotAvatar.src=src;OMSBotAvatar.upgrade=async()=>src;},'data:image/webp;base64,'+fs.readFileSync('bot-avatar-helper.webp').toString('base64'));
  await page.evaluate(()=>{__items=[
   {message_id:'booking',property_id:'home',message:'[OMS-BOOKING:321]\n당일 예약 접수\nJAE YUB KIM · 507\n2026-11-15 → 2026-11-17 · Booking.com'},
   {message_id:'branch',property_id:'branch',property_name:'Seoulnest',message:'[OMS-BOOKING:322]\n당일 예약 알림\nAida María · Martín Montesinos <img src=x> · 201호\n2026-11-15 → 2026-11-16 · Booking.com'}
  ].map(i=>({...i,sender_type:'system',message_type:'general',created_at:'2026-11-15T11:51:00Z'}));});
  for(const file of scripts)await page.addScriptTag({content:fs.readFileSync(file,'utf8')});
  await page.evaluate(()=>start());await page.locator('.bot-booking-property').first().waitFor();
  const first=page.locator('[data-bot-row=booking]'),second=page.locator('[data-bot-row=branch]');
  assert.equal(await first.locator('.bot-booking-room').innerText(),'507호');
  assert.equal(await first.locator('.bot-booking-property').innerText(),'· One Minute');
  assert.equal(await first.locator('.bot-booking-dates').innerText(),'11.15 → 11.17');
  assert.equal(await second.locator('.bot-booking-property').innerText(),'· Seoulnest');
  assert.equal(await second.locator('.bot-booking-guest').innerText(),'Aida María · Martín Montesinos <img src=x>');
  assert.equal(await second.locator('.bot-booking-guest img').count(),0);
  assert(await page.locator('#botTimeline').evaluate(el=>el.scrollWidth<=el.clientWidth));
  assert((await page.locator('.bot-booking-property,.bot-booking-channel').evaluateAll(xs=>xs.map(x=>x.scrollWidth<=x.clientWidth))).every(Boolean),'normal property and channel names remain fully visible');
  await page.locator('#botTimeline').evaluate(el=>el.scrollTop=0);
  await page.screenshot({path:'/tmp/oms-booking-pink-'+width+'.png'});
  await first.getByRole('button',{name:'예약 상세'}).click();await page.waitForURL('https://fixture.test/online.html#booking-data?property=home&booking=321');
  await page.close();console.log('Pink booking card '+width+'px: legacy/current envelopes, branch names, safe long names, compact dates and owner deep link passed');
 }}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
