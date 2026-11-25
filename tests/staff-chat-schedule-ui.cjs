const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('fs'),{JSDOM}=require('jsdom');
const tick=(ms=20)=>new Promise(r=>setTimeout(r,ms));
test('long press queues only after confirmation; normal send stays immediate; edit and cancel stay scoped',async()=>{
 const dom=new JSDOM('<form><button id="send">send</button></form><button id="list"></button>',{url:'https://omgworks24.com/staff-chat.html',runScripts:'outside-only'}),w=dom.window,d=w.document;
 w.GuestSupport={esc:s=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;')};w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};w.confirm=()=>true;
 const calls=[],items=[],employee='00000000-0000-4000-8000-000000000031';let accepted=0,immediate=0;
 d.querySelector('form').onsubmit=ev=>{ev.preventDefault();immediate++;};
 w.eval(fs.readFileSync('staff-chat-schedule.js','utf8'));
 const controller=w.OMSStaffSchedule.bind({send:d.querySelector('#send'),listButton:d.querySelector('#list'),draft:()=>({body:'원문',priority:'normal',photo:'data:image/jpeg;base64,/9j/AA=='}),accepted:()=>accepted++,members:()=>[],call:async(a,data)=>{calls.push({a,data});if(a==='schedule_create')items.push({...data,id:'job1',revision:1,trigger_name:'직원'});if(a==='schedule_cancel')items.length=0;return{ok:true,items,recipients:[{id:employee,name:'직원'}]};}});
 await controller.refresh();assert.equal(d.querySelector('#list').hidden,true);d.querySelector('#send').click();assert.equal(immediate,1);
 function pointer(type,x=0){d.querySelector('#send').dispatchEvent(new w.MouseEvent(type,{button:0,clientX:x,bubbles:true}));}
 pointer('pointerdown');await tick(600);pointer('pointerup');d.querySelector('#send').click();await tick();assert.equal(immediate,1);assert.equal(calls.filter(x=>x.a==='schedule_create').length,0);assert.ok(d.querySelector('dialog').open);
 const mode=d.querySelector('[data-mode=checkin]');mode.click();await tick();d.querySelector('.schedule-save').click();await tick();assert.equal(accepted,1);assert.equal(d.querySelector('#list').hidden,false);assert.ok(d.querySelector('#list svg circle[fill=\"#e65359\"]'));const sent=calls.find(x=>x.a==='schedule_create').data;assert.equal(sent.mode,'checkin');assert.equal(sent.trigger_employee_id,employee);assert.equal(sent.send_at,null);assert.ok(sent.photo);
 d.querySelector('#list').click();await tick();d.querySelector('[data-edit]').click();await tick();d.querySelector('textarea').value='수정';d.querySelector('.schedule-save').click();await tick();assert.equal(calls.find(x=>x.a==='schedule_update').data.id,'job1');assert.equal(accepted,1);
 d.querySelector('#list').click();await tick();d.querySelector('[data-edit]').click();await tick();d.querySelector('[data-cancel]').click();await tick();assert.equal(calls.find(x=>x.a==='schedule_cancel').data.revision,1);assert.equal(d.querySelector('#list').hidden,true);
 pointer('pointerdown');pointer('pointermove',30);await tick(600);pointer('pointerup');d.querySelector('#send').click();assert.equal(immediate,2);w.close();
});
test('calendar update shown only for newer native version and invokes native installer',async()=>{
 for(const [installed,latest,visible] of [[8,8,false],[8,9,true],[8,7,false]]){
 const dom=new JSDOM('<div class="calendar-top"><a>OMS 캘린더</a></div><button id="companionSettings"></button>',{url:'https://omgworks24.com/calendar.html?app=1',runScripts:'outside-only'}),w=dom.window;let clicks=0;
 w.OMSCalendarAndroid={getAppInfo:()=>JSON.stringify({version_code:installed}),checkForUpdate:()=>clicks++};w.fetch=async()=>({json:async()=>({version_code:latest})});w.eval(fs.readFileSync('calendar-companion.js','utf8'));await tick();const button=w.document.querySelector('#calendarUpdate');assert.equal(!button.hidden,visible);assert.equal(button.previousElementSibling.textContent,'OMS 캘린더');if(visible){button.click();assert.equal(clicks,1);}w.close();}
});
