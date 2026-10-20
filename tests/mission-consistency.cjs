// Regression: completed 1/1 tasks returned by old calendar endpoints must never reappear as overdue.
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const read=f=>fs.readFileSync(f,'utf8'),now='2026-10-20T08:00:00Z',past='2026-10-03T14:59:59Z';
const base={active:true,timing:'today',priority:'normal',completion_mode:'all',target_count:1,completed_count:0,target_employee_ids:['a'],property_id:'own',property_name:'One Minute',is_own_property:true};
const missions=[
 {...base,id:'done1',title:'테슷',due_at:past,completed_count:1,completion_employee_ids:['a']},
 {...base,id:'done2',title:'줄넘기',due_at:past,completed_count:1,completion_employee_ids:['a']},
 {...base,id:'done-any',title:'누구든 완료',due_at:past,completion_mode:'any',target_count:5,completed_count:1,completion_employee_ids:['b']},
 {...base,id:'done-owner',title:'관리자 완료',due_at:past,owner_completed_at:now},
 {...base,id:'late',title:'미완료 지연',due_at:past,target_count:2,completed_count:1,completion_employee_ids:['a'],target_employee_ids:['a','b']},
 {...base,id:'remote',title:'오엠지미숀',due_at:null,target_employee_ids:['b'],property_id:'remote',property_name:'omg house',is_own_property:false},
 {...base,id:'today-earlier',title:'오늘 아침 마감',due_at:'2026-10-19T23:00:00Z'},
 {...base,id:'future',title:'내일 할 일',due_at:'2026-10-21T14:59:59Z'},
];
function env(file,session){
 const dom=new JSDOM(read(file),{url:'https://oms.test/'+file,runScripts:'outside-only'}),w=dom.window,calls=[];
 const RealDate=w.Date;w.Date=class extends RealDate{constructor(...args){super(...(args.length?args:[now]));}static now(){return RealDate.parse(now);}};
 w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});let data={ok:true};
  if(name==='list_property_shares')data.properties=[{property_id:'own',is_own:true},{property_id:'remote',permissions:['missions']},{property_id:'denied',permissions:['messages']}];
  if(name==='list_shared_missions'||name==='list_missions')data={ok:true,missions:missions.filter(m=>name==='list_missions'?m.property_id==='own':!args.p_property_ids||args.p_property_ids.includes(m.property_id)),employees:[]};
  if(name==='calendar_event_action'||name==='list_shared_calendar_board'||name==='list_overdue_calendar_tasks')data={ok:true,events:[],tasks:missions.slice(0,2),employees:[]};
  return {data};}};
 w.omgTransition={ready(){}};w.omgSession={require:async()=>session};w.eval(read('worker-tasks.js'));return {dom,w,calls};
}
const owner={sessionKind:'owner',accessToken:'synthetic',propertyId:'own',timezone:'Asia/Seoul'},worker={...owner,sessionKind:'staff',employeeId:'a'};
(async()=>{
 for(const [session,expected] of [[owner,['late','remote','today-earlier']],[worker,['today-earlier']]]){
  const home=env('app.html',session),{w}=home;
  w.eval(read('app.html').slice(read('app.html').indexOf('async function loadMissionSummary'),read('app.html').indexOf('(async () => {',read('app.html').indexOf('async function loadMissionSummary'))));
  w.escapeWorking=String;await w.loadMissionWidgets(session,session.sessionKind==='owner');
  assert.equal(Number(w.document.querySelector('#todayMissionCount').textContent),expected.length);
  const texts=[...w.document.querySelectorAll('.today-overview-item')].map(n=>n.textContent);assert.equal(texts.length,expected.length);assert(!texts.some(x=>x.includes('테슷')||x.includes('줄넘기')));
  assert.equal(home.calls.filter(x=>['list_shared_missions','list_missions'].includes(x.name)).length,1);
  assert(!home.calls.some(x=>x.name==='list_overdue_calendar_tasks'));
  if(session===owner){assert.deepEqual(home.calls.find(x=>x.name==='list_shared_missions').args.p_property_ids,['own','remote']);assert.equal(w.document.querySelector('.oms-mission-property').title,'omg house');}
  assert(![...w.document.querySelectorAll('.today-overview-item.late')].some(n=>n.textContent.includes('오늘 아침 마감')));
  home.dom.window.close();
  const cal=env('calendar.html',session);cal.w.omgWorkConfig={load:async()=>({property:{property_id:'own'}})};cal.w.omgPropertySelector={mount:async()=>({selectedIds:()=>['own','remote']})};cal.w.eval(read('calendar.js'));await new Promise(r=>setTimeout(r,30));
  for(const view of ['week','day','month']){cal.w.document.querySelector('[data-view='+view+']').click();await new Promise(r=>setTimeout(r,10));const ids=[...cal.w.document.querySelectorAll('[data-kind=task]')].map(n=>n.dataset.id);if(view!=='month')assert.deepEqual(new Set(ids),new Set(view==='day'?expected:[...expected,'future']));else{assert(ids.includes('future'));assert(ids.every(id=>[...expected,'future'].includes(id)));}assert(!cal.w.document.querySelector('[data-id=today-earlier] .calendar-late-badge'));}
  assert(!cal.calls.some(x=>x.name==='list_overdue_calendar_tasks'));cal.dom.window.close();
 }
 const todo=env('mission.html',owner),w=todo.w;w.eval(read('property-selector.js'));w.eval(read('select-picker.js'));
 const script=[...w.document.scripts].findLast(s=>!s.src).textContent.split('(async()=>{session=')[0];
 w.eval(script+`;session=${JSON.stringify(owner)};config={property:{property_id:'own'}};isOwner=true;missions=${JSON.stringify(missions)};render();`);
 assert.equal(w.document.querySelector('#sumOverdue').textContent,'1');assert.equal(w.document.querySelector('#sumToday').textContent,'2');assert.equal(w.document.querySelector('#sumDone').textContent,'4');
 assert.equal(w.document.querySelector('#section-today .oms-mission-property').title,'omg house');assert.equal(w.document.querySelector('#section-overdue .oms-mission-property'),null);
 for(const [name,lines] of [['omg house',['omg h','ouse']],['1234567890',['12345','67890']],['12345678901',['12345','678..']],['가나다라마바사아자차카',['가나다라마','바사아..']],['👨‍👩‍👧‍👦abcde',['👨‍👩‍👧‍👦abcd','e']]]){
  const span=w.document.createElement('div');span.innerHTML=w.OMSMissionTasks.propertyTag({property_name:name,is_own_property:false},'own');assert.deepEqual([...span.querySelectorAll('b')].map(n=>n.textContent),lines);
 }
 assert.equal(w.OMSMissionTasks.propertyTag({property_name:'own',is_own_property:true},'own'),'');
 assert(!w.OMSMissionTasks.propertyTag({property_name:'<img onerror=1>',is_own_property:false},'own').includes('<img'));
 todo.dom.window.close();console.log('PASS: home/To do/all calendar views share completed, overdue, today, employee and branch rules; five-grapheme/two-line escaped branch prefixes.');
})().catch(e=>{console.error(e);process.exitCode=1});
