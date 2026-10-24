const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{JSDOM}=require('jsdom');
const html=fs.readFileSync('calendar.html','utf8').replace(/<script[\s\S]*?<\/script>/g,'');
const tick=()=>new Promise(resolve=>setTimeout(resolve,10));
async function open(storage={},id='worker-a',blocked=false){
 const dom=new JSDOM(html,{url:'https://omgworks24.com/calendar.html',runScripts:'outside-only'}),w=dom.window,calls=[];
 // Fixed February starting on Sunday, including a month that ends on Saturday.
 w.Date.now=()=>Date.parse('2026-02-15T03:00:00Z');
 if(blocked)Object.defineProperty(w,'localStorage',{get(){throw Error('Storage disabled');}});
 else for(const [key,value]of Object.entries(storage))w.localStorage.setItem(key,value);
 w.omgSession={require:async()=>({sessionKind:'staff',employeeId:id,accessToken:'fixture',timezone:'Asia/Seoul'})};
 w.omgTransition={ready(){}};w.OMSWorkerTasks={events:x=>x};w.OMSMissionTasks={load:async()=>({missions:[]}),pending:x=>x};
 w.omgSupabase={rpc:async(name,args)=>{calls.push(args);return {data:{ok:true,events:[],tasks:[],employees:[]}};}};
 w.eval(fs.readFileSync('calendar.js','utf8'));await tick();
 return {w,d:w.document,calls,storage:()=>Object.fromEntries(Object.keys(w.localStorage).map(k=>[k,w.localStorage.getItem(k)]))};
}
test('fresh month starts Sunday and request range includes precisely the visible dates',async()=>{
 const c=await open();assert(c.d.querySelector('.calendar-month'));
 assert.deepEqual([...c.d.querySelectorAll('.calendar-weekdays span')].map(x=>x.textContent),['일','월','화','수','목','금','토']);
 const days=[...c.d.querySelectorAll('.calendar-day')];assert.equal(days.length,28);assert.equal(days[0].dataset.date,'2026-02-01');assert.equal(days.at(-1).dataset.date,'2026-02-28');
 assert.equal(c.calls[0].p_event.range_start,'2026-01-31T15:00:00.000Z');assert.equal(c.calls[0].p_event.range_end,'2026-02-28T15:00:00.000Z');
 c.d.getElementById('prevButton').click();await tick();assert.equal(c.d.querySelector('.calendar-day').dataset.date,'2025-12-28');
 c.w.close();
});
test('week/day/month choices survive re-entry without a preference network request and are account-scoped',async()=>{
 let saved={};
 for(const view of ['week','day','month']){
  const c=await open(saved);c.d.querySelector(`[data-view="${view}"]`).click();await tick();saved=c.storage();c.w.close();
  const back=await open(saved);assert.equal(back.d.querySelector(`[data-view="${view}"]`).getAttribute('aria-pressed'),'true');assert.equal(back.calls.length,1,'one normal list query');back.w.close();
 }
 const c=await open();c.d.querySelector('[data-view="week"]').click();await tick();saved=c.storage();c.w.close();
 const other=await open(saved,'worker-b');assert(other.d.querySelector('.calendar-month'));other.w.close();
});
test('invalid or blocked local storage falls back to month and does not prevent switching',async()=>{
 for(const blocked of [false,true]){
  const c=await open({'oms.calendar.view.v1:staff:worker-a':'invalid'},'worker-a',blocked);
  assert(c.d.querySelector('.calendar-month'));c.d.querySelector('[data-view="week"]').click();await tick();assert(c.d.querySelector('.calendar-week-grid'));c.w.close();
 }
});
