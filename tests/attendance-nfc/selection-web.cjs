const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const tick=()=>new Promise(r=>setTimeout(r,10));
(async()=>{
 const w=new JSDOM('<a id="report" href="report.html?type=clock_in">출근보고</a>',{url:'https://omgworks24.com/app.html',runScripts:'outside-only'}).window;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(value){this.returnValue=value;this.open=false;this.dispatchEvent(new w.Event('close'));};
 w.omgSession={get:()=>({timezone:'Asia/Seoul',status:'working'})};w.eval(fs.readFileSync('attendance-flow.js','utf8'));
 let state={basis:'nfc',status:'working',nfc_entries:[]},selected=[],opened=[],stopped=0;
 const controller={refresh:async()=>state,select:async id=>{selected.push(id);},stop:()=>stopped++};
 w.OMSAttendanceFlow.bindCheckin(w.document.querySelector('a'),controller,url=>opened.push(url));
 const click=()=>w.document.querySelector('a').click();click();await tick();assert.equal(w.document.querySelector('h2').textContent,'새로 NFC 태그해주세요');assert.equal(w.document.querySelectorAll('dialog button').length,1,'no bypass without tag');w.document.querySelector('dialog button').click();await tick();assert.equal(opened.length,0);
 state.nfc_entries=[{id:'first',recorded_at:'2026-11-24T00:00:00Z'}];click();await tick();assert.deepEqual(selected,['first']);assert.equal(opened.length,1);assert(!w.document.querySelector('dialog'));
 state.nfc_entries.push({id:'second',recorded_at:'2026-11-24T00:15:00Z'});click();click();await tick();let d=w.document.querySelector('dialog');assert.equal(w.document.querySelectorAll('dialog').length,1);assert.equal(d.querySelectorAll('input').length,2);assert(d.textContent.includes('09:15:00'));assert(d.querySelector('[data-confirm]').disabled);assert.equal(opened.length,1,'form stays closed until selected');d.querySelector('[data-cancel]').click();await tick();assert.equal(opened.length,1);assert.deepEqual(selected,['first']);
 click();await tick();d=w.document.querySelector('dialog');const radio=d.querySelector('[value=second]');radio.checked=true;radio.dispatchEvent(new w.Event('change'));d.querySelector('[data-confirm]').click();await tick();assert.deepEqual(selected,['first','second']);assert.equal(opened.length,2);assert.equal(stopped,2);
 state={basis:'report',status:'working'};click();await tick();assert.equal(opened.length,3,'non NFC unchanged');assert.equal(selected.length,2);w.close();
 console.log('PASS menu-entry NFC: no-tag blocks with exact prompt, one auto-selects, multiple choose before opening form, cancel and double-click, non-NFC unaffected');
})().catch(e=>{console.error(e);process.exitCode=1;});
