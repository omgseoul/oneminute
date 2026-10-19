// Real browser tests with synthetic accounts only; all external requests are intercepted.
const {chromium}=require('playwright'),http=require('http'),fs=require('fs'),path=require('path'),assert=require('assert/strict');
const root=path.resolve(__dirname,'../..'),output=process.env.OMS_UI_OUTPUT||'/tmp/oms-unread-ui';fs.mkdirSync(output,{recursive:true});
const fixture=`
const pid='11111111-1111-4111-8111-111111111111',eid='22222222-2222-4222-8222-222222222222',other='33333333-3333-4333-8333-333333333333',peer='owner:44444444-4444-4444-8444-444444444444';
window.__calls=[];window.__session={accessToken:'synthetic',sessionKind:'staff',propertyId:pid,employeeId:location.search.includes('second')?other:eid,employeeName:'근무자',timezone:'Asia/Seoul'};
const now=new Date(),today=now.toISOString(),past=new Date(now-3*86400000).toISOString();
const task=(id,title,targets=[],extra={})=>({id,title,target_employee_ids:targets,due_at:today,completion_employee_ids:[],...extra});
window.__tasks=[task('mine','본인 오늘 할 일',[eid]),task('other','다른 직원 할 일',[other]),task('mine-done','본인 완료',[eid],{completion_employee_ids:[eid]}),task('any-done','누군가 완료',[],{completion_mode:'any',completed_count:1}),task('owner-done','사장 완료',[],{owner_completed_at:today}),task('late','본인 지연',[eid],{due_at:past}),task('today','날짜 없는 오늘 할 일',[eid],{due_at:null,timing:'today'})];
window.__rooms=[{peer,name:'사장님',property_id:pid,property_name:'One Minute',updated_at:today,preview:'안녕하세요',unread:2}];
window.__messages=[{id:'a',body:'안녕하세요',mine:false,read_at:null,created_at:today},{id:'b',body:'확인 부탁합니다',mine:false,read_at:null,created_at:today}];
window.__alerts=[{message_id:'notice',property_id:pid,message:'직접 확인이 필요한 공지',message_type:'announcement',sender_type:'owner',created_at:today,require_signature:true,require_understanding:true,read_at:null},{message_id:'ordinary',property_id:pid,message:'읽으면 카운터가 줄어드는 소식',message_type:'holiday_notice',sender_type:'system',created_at:today,require_signature:false,require_understanding:false,read_at:null}];
window.omgSession={require:async()=>window.__session};window.omgTransition={ready(){document.documentElement.classList.remove('omg-booting')}};window.OMGNative={refreshMessageBadge(){__calls.push({name:'native-refresh'})},setMessageBadge(token,count){window.__badge=count}};
window.omgSupabase={rpc:async(name,args={})=>{__calls.push({name,args});let data={ok:true};
if(name==='get_work_configuration')data={ok:true,can_manage:false,property:{id:pid,name:'One Minute'},report_config:{}};
if(name==='list_working_employees')data={ok:true,own_property_id:pid,own_property_name:'One Minute',employees:[]};
if(name==='list_missions')data={ok:true,missions:__tasks};
if(name==='calendar_event_action')data={ok:true,events:[],tasks:__tasks};
if(name==='list_overdue_calendar_tasks')data={ok:true,tasks:__tasks.filter(t=>t.id==='late'||t.id==='other')};
if(name==='list_property_messages')data={ok:true,can_manage:false,messages:location.pathname.endsWith('app.html')?[]:__alerts,recipients:[],unread_count:__messages.filter(m=>!m.read_at).length+__alerts.filter(m=>!m.read_at).length};
if(name==='staff_chat_peer_profile')data={ok:true,profile:{display_name:'사장님',property_name:'One Minute'}};
if(name==='staff_chat_rpc'){
 if(args.p_action==='rooms')data={ok:true,rooms:__rooms};
 if(args.p_action==='messages')data={ok:true,can_send:true,peer:{display_name:'사장님'},messages:args.p_data.after_time?[]:__messages};
 if(args.p_action==='read'){let ids=args.p_data.ids;__messages.forEach(m=>{if(ids.includes(m.id))m.read_at=new Date().toISOString()});data={ok:true,read_ids:ids,unread_count:__messages.filter(m=>!m.read_at).length};}
 if(args.p_action==='leave'){__rooms=[];__messages.forEach(m=>m.read_at=now.toISOString());}
}
if(name==='notification_bot_settings')data={ok:true,bots:[{property_id:pid,display_name:'OMS 알림',property_name:'One Minute'}]};
if(name==='list_notification_bot_messages')data={ok:true,messages:__alerts,unread_by_property:{[pid]:__alerts.filter(m=>!m.read_at).length}};
if(name==='mark_property_message_read'){__alerts.find(m=>m.message_id===args.p_message_id).read_at=new Date().toISOString();}
if(name==='holiday_request_action'){
 if(args.p_action==='context')data={ok:true,today:'2026-10-20',employee_id:eid,employees:[{id:eid,name:'신청 근무자'},{id:other,name:'동료'}],settings:{notice_enabled:false}};
 if(args.p_action==='submit'){if(window.__failHoliday)return {error:{message:'시험 저장 실패'}};data={ok:true,id:'request',message_id:'saved'};}
}
return {data};}};
window.omgNotifications={send:async()=>({ok:true})};
`;
const server=http.createServer((req,res)=>{const name=new URL(req.url,'http://localhost').pathname.slice(1);res.setHeader('Content-Type',(name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html')+';charset=utf-8');
if(name==='qa-font.otf'&&process.env.OMS_QA_FONT){res.setHeader('Content-Type','font/otf');res.end(fs.readFileSync(process.env.OMS_QA_FONT));return;}
if(name==='supabase-client.js'){res.end(fixture);return;}
if(name==='work-config.js'){res.end(`window.omgWorkConfig={load:async()=>({can_manage:false,property:{id:'11111111-1111-4111-8111-111111111111',name:'One Minute',management_number:1}})};`);return;}
if(name==='holiday-test.html'){res.end('<html lang="ko"><head><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="holiday-request.css"></head><body><button id="requestHoliday">휴일 신청</button><p id="message"></p><script src="supabase-client.js"></script><script src="holiday-request.js"></script><script>HolidayRequest.init(__session)</script></body></html>');return;}
const file=path.resolve(root,name);if(!file.startsWith(root+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}res.end(fs.readFileSync(file));});
(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH||'/root/.cache/ms-playwright/chromium_headless_shell-1161/chrome-linux/headless_shell'});try{
const page=await browser.newPage({viewport:{width:390,height:844}});if(process.env.OMS_QA_FONT)await page.addInitScript(()=>addEventListener('DOMContentLoaded',()=>{const style=document.createElement('style');style.textContent='@font-face{font-family:QA;src:url(qa-font.otf)}body,button,input,textarea{font-family:QA,sans-serif!important}';document.head.append(style);}));const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.route('**/*',async route=>{const url=new URL(route.request().url());if(url.origin===origin)return route.continue();if(url.pathname.includes('/functions/v1/guest-support'))return route.fulfill({json:{ok:true,actor:{key:'employee:test'},rooms:[],properties:[{id:'11111111-1111-4111-8111-111111111111',name:'One Minute'}]}});return route.fulfill({body:'',contentType:'application/javascript'});});
await page.goto(origin+'/app.html');await page.waitForFunction(()=>document.querySelector('#todayOverviewItems').textContent.includes('본인 오늘 할 일'));let text=await page.locator('#todayOverviewItems').textContent();assert(text.includes('본인 지연')&&text.includes('날짜 없는 오늘 할 일'));for(const s of ['다른 직원','본인 완료','누군가 완료','사장 완료'])assert(!text.includes(s),s);assert.equal(await page.locator('#todayMissionCount').textContent(),'3');await page.screenshot({path:output+'/worker-home.png'});
await page.goto(origin+'/app.html?second');await page.waitForFunction(()=>document.querySelector('#todayOverviewItems').textContent.includes('다른 직원'));assert(!(await page.locator('#todayOverviewItems').textContent()).includes('본인 오늘'));
await page.goto(origin+'/messages.html?tab=staff');await page.locator('[data-hub=staff]').click();const room=page.locator('.staff-room[data-peer]');await room.waitFor();const rect=await room.boundingBox();await page.mouse.move(rect.x+80,rect.y+30);await page.mouse.down();await page.waitForFunction(()=>document.querySelector('#staffRoomMenu').open);await page.mouse.up();assert(page.url().includes('messages.html'));await page.screenshot({path:output+'/room-leave-menu.png'});await page.locator('#staffRoomLeave').click();await page.waitForFunction(()=>!document.querySelector('.staff-room[data-peer]'));
await page.locator('.bot-room').click();await page.waitForFunction(()=>__alerts.find(m=>m.message_id==='ordinary').read_at);assert.equal(await page.evaluate(()=>__alerts.find(m=>m.message_id==='notice').read_at),null);assert(await page.evaluate(()=>__calls.some(c=>c.name==='native-refresh')));await page.waitForFunction(()=>document.querySelector('#staffCount').textContent==='1');
await page.goto(origin+'/staff-chat.html?peer=owner:44444444-4444-4444-8444-444444444444');await page.waitForFunction(()=>__messages.every(m=>m.read_at));assert.equal(await page.locator('.message-unread').count(),0);assert(await page.evaluate(()=>__calls.some(c=>c.name==='staff_chat_rpc'&&c.args.p_action==='read')));
await page.goto(origin+'/holiday-test.html');await page.locator('#requestHoliday').click();await page.locator('#holidayReason').fill('가족 일정 <img src=x onerror=alert(1)>');await page.evaluate(()=>window.__failHoliday=true);await page.locator('#holidaySubmit').click();await page.waitForFunction(()=>document.querySelector('#holidayError').textContent.includes('시험 저장 실패'));assert.equal(await page.locator('#holidaySuccessDialog').evaluate(e=>e.open),false);await page.evaluate(()=>window.__failHoliday=false);await page.locator('#holidaySubmit').click();await page.waitForFunction(()=>document.querySelector('#holidaySuccessDialog').open);text=await page.locator('#holidaySuccessDetails').textContent();assert(text.includes('2026-10-20')&&text.includes('신청 근무자')&&text.includes('가족 일정'));assert.equal(await page.locator('#holidaySuccessDetails img').count(),0);assert.equal(await page.locator('#holidaySuccessTitle').textContent(),'휴일신청되었습니다.');await page.evaluate(()=>holidaySuccessDetails.lastElementChild.textContent='가족 일정으로 휴일을 신청합니다.');await page.screenshot({path:output+'/holiday-success.png'});await page.locator('#holidaySuccessDialog button').click();assert.equal(await page.locator('#holidaySuccessDialog').evaluate(e=>e.open),false);
assert.deepEqual(errors,[]);console.log('PASS worker account/completion filtering, room long press and leave, visible BOT/chat reads, acknowledgement preserved, holiday error/success and escaped details');
}finally{await browser.close();await new Promise(r=>server.close(r));}})().catch(e=>{console.error(e);process.exitCode=1;server.close();});
