const {chromium}=require('playwright');
const fs=require('node:fs');const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:390,height:844}});
 const room='11111111-1111-4111-8111-111111111111';
 await page.route('https://fixture.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><div class="top"></div><div id="staffRooms"></div><span id="staffCount"></span><div id="detail" hidden></div><div id="composeOverlay" hidden></div>'}));
 await page.goto('https://fixture.test/messages.html');
 await page.addStyleTag({content:fs.readFileSync('message-hub.css','utf8')});
 await page.evaluate(room=>{
  window.GuestSupport={esc:s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
  window.StaffChat={contractId:()=>null,cleanText:s=>s};window.OMSBotAvatar={upgrade:async()=>null};
  window.__detailCalls=0;
  window.omgSupabase={rpc:async(name)=>({data:name==='notification_bot_settings'?{ok:true,bots:[]}:{ok:true,unread_by_property:{p:1},messages:[{message_id:'m1',property_id:'p',sender_type:'system',sender_label:'AI 지원요청',message_type:'general',guest_chat_room_id:room,message:'[OMS-GUEST-CHAT:'+room+']\nAI 메시지 지원요청\n401호 게스트 문의가 왔습니다.\n청소 상태를 확인해주세요.',created_at:new Date().toISOString()}]}})};
 },room);
 await page.addScriptTag({content:fs.readFileSync('notification-bot.js','utf8')});
 await page.evaluate(()=>NotificationBot.init({propertyId:'p',accessToken:'fixture'},{refresh:async()=>{},openDetail:()=>__detailCalls++,compose:()=>{}}));
 await page.locator('.bot-room').click();
 const action=page.getByRole('button',{name:'게스트 대화 열기'});await action.waitFor();
 assert(!(await page.locator('#botTimeline').innerText()).includes('OMS-GUEST-CHAT:'));
 await page.screenshot({path:'/tmp/oms-ai-support-mobile.png',fullPage:true});
 await action.click();await page.waitForURL('https://fixture.test/guest-chat.html?room='+room);
 console.log('PASS bot: persistent guest support card, clean message, correct room navigation');await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
