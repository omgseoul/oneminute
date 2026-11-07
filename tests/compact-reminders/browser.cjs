const{chromium}=require('playwright'),fs=require('fs'),path=require('path'),http=require('http'),vm=require('vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../..');const source=fs.readFileSync(path.join(root,'tests/notification-bot-ui.cjs'),'utf8');const sandbox={require,process,__dirname:path.join(root,'tests')};vm.runInNewContext(source.slice(0,source.indexOf('(async()=>'))+';globalThis.fixture=fixture;',sandbox);
const extra=`
window.__items=[
 ['To do 알림','지연: 냉장고 점검'],
 ['To do 알림','3일 지연: 공용공간 정리\\n마감: 2026-11-04 23:59'],
 ['To do 알림','오늘: 수건 재고 확인\\n마감: 2026-11-07 23:59'],
 ['일정 알림','오늘: 오후 3시 소방점검\\n일정: 2026-11-07 15:00'],
 ['일정 알림','2일 후: 에어컨 필터 청소\\n일정: 2026-11-09 15:00'],
 ['일정 알림','3일 후: 정기 방역\\n일정: 2026-11-10 15:00'],
 ['To do 알림','오늘: 체크인 안내문 확인\\n마감: 2026-11-07 23:59']
].map((x,i)=>({message_id:'r'+i,property_id:pid,reminder_at:i===0?'2026-11-06T14:59:00Z':null,reminder_timezone:'Asia/Seoul',message:x[0]+'\\n'+x[1]+'\\n시간대: Asia/Seoul',sender_type:'system',sender_label:x[0],message_type:'general',created_at:'2026-11-07T02:29:0'+i+'Z',read_at:'2026-11-07T02:30Z'}));
`;
const server=http.createServer((req,res)=>{const file=path.resolve(root,'.'+new URL(req.url,'http://local').pathname);if(!file.startsWith(root+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return}res.setHeader('Content-Type',({'.js':'text/javascript','.css':'text/css','.html':'text/html','.webp':'image/webp','.jpg':'image/jpeg'})[path.extname(file)]||'application/octet-stream');res.end(fs.readFileSync(file))});
(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port+'/';const browser=await chromium.launch();try{
for(const width of [320,390,540]){const context=await browser.newContext({viewport:{width,height:844}});await context.route('**/*',route=>{const url=route.request().url();if(!url.startsWith(base))return route.fulfill({contentType:'application/javascript',body:''});const file=new URL(url).pathname.slice(1);if(file==='supabase-client.js')return route.fulfill({contentType:'application/javascript',body:sandbox.fixture+extra});if(['guest-support-client.js','property-selector.js','work-config.js','warning-targets.js'].includes(file))return route.fulfill({contentType:'application/javascript',body:''});return route.continue()});
const p=await context.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));await p.clock.setFixedTime(new Date('2026-11-07T07:00Z'));await p.goto(base+'messages.html?tab=staff');await p.locator('.bot-room').click();await p.waitForSelector('.bot-reminder-panel');
assert.equal(await p.locator('.bot-reminder-group').count(),1);assert.equal(await p.locator('.bot-reminder-item').count(),7);assert.equal(await p.locator('.bot-reminder-group .bot-chat-avatar').count(),1);assert.equal(await p.locator('.bot-reminder-group .bot-chat-meta').count(),1);
assert.deepEqual(await p.locator('.bot-reminder-heading').allTextContents(),['[지연] To do+1일','[지연] To do+3일','To do','일정 알림 (오늘)','일정 알림 (2일 후)','일정 알림 (3일 후)','To do']);assert.equal(await p.locator('.bot-reminder-line p').first().innerText(),'냉장고 점검');
for(const r of await p.locator('.bot-reminder-line button').evaluateAll(xs=>xs.map(x=>{const b=x.getBoundingClientRect();return{x:b.x,right:b.right,height:b.height}}))){assert(r.x>=0&&r.right<=width,'buttons fit screen');assert(r.height<=30,'single-line button height')}
const visible=await p.locator('.bot-reminder-item').evaluateAll(xs=>{const r=document.getElementById('botTimeline').getBoundingClientRect();return xs.filter(x=>{const b=x.getBoundingClientRect();return b.top>=r.top&&b.bottom<=r.bottom}).length});assert(visible>=6,'at least six readable alerts in viewport');
await p.screenshot({path:'/tmp/oms-compact-bot-'+width+'.png'});
await p.locator('[data-bot-message="r4"]').click();await p.waitForSelector('#detail:visible');assert.match(await p.locator('#detail').innerText(),/에어컨 필터 청소/);
// Adjacent branch/day boundaries and actionable non-reminders remain separate.
await p.evaluate(()=>{document.getElementById('detail').hidden=true;__items[2].property_id=pid2;__items[3].message_type='attendance_warning';__items[3].message='근태 경고';__items[3].sender_label='근태관리';NotificationBot.update({messages:__items},null)});await p.waitForTimeout(500);assert.equal(await p.locator('.bot-reminder-group').count(),3);assert.equal(await p.locator('.bot-chat-row:not(.bot-reminder-group)').count(),1);assert.match(await p.locator('.bot-chat-row:not(.bot-reminder-group)').innerText(),/내용 확인/);
await p.evaluate(()=>{__items[6].created_at='2026-11-08T02:29:00Z';NotificationBot.update({messages:__items},null)});await p.waitForTimeout(300);assert.equal(await p.locator('.bot-reminder-group').count(),4);assert.equal(await p.locator('.bot-date').count(),2);assert.deepEqual(errors,[]);await context.close();console.log('PASS compact bot '+width+'px: grouping, dates, buttons, detail target and branch/approval boundaries');
}
}finally{await browser.close();server.close()}})().catch(e=>{console.error(e);server.close();process.exitCode=1});
