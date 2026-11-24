const fs=require('fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const html=fs.readFileSync('mission.html','utf8'),source=fs.readFileSync('mission-widget.js','utf8');
const id='00000000-0000-4000-8000-000000000001';
function setup(url='https://omgworks24.com/mission.html?app=todo&scope=mine&task='+id, native=true){
 const dom=new JSDOM(html,{url,runScripts:'outside-only'}),w=dom.window,calls=[];
 w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 w.OMSMissionTasks={privateAction:async()=>({ok:true})};
 if(native)w.OMSCalendarAndroid={setSession:(...a)=>calls.push(['session',...a]),exitToLauncher:()=>calls.push(['exit']),refreshWidgets:()=>calls.push(['refresh']),clearSession:()=>calls.push(['clear'])};
 w.eval(source);return {dom,w,calls};
}
(async()=>{
 const {dom,w,calls}=setup(),item={id,title:'선택한 할 일'},session={accessToken:'test',sessionKind:'owner',ownerId:'owner',propertyId:'property'};
 const open=record=>{assert.equal(record,item);w.document.getElementById('detailOverlay').hidden=false;};
 w.OMSWidgetNavigation.ready(session,[item],open);assert(!w.document.getElementById('detailOverlay').hidden);assert(!w.location.search.includes('task='));
 assert.equal(w.OMSWidgetNavigation.back(),true);assert(w.document.getElementById('detailOverlay').hidden);assert.equal(w.OMSWidgetNavigation.back(),false);
 w.OMSWidgetNavigation.ready(session,[item],()=>assert.fail('must not reopen on refresh'));
 w.document.querySelector('.back').click();assert(calls.some(c=>c[0]==='exit'));
 const dialog=w.document.createElement('dialog');w.document.body.append(dialog);dialog.open=true;w.document.getElementById('detailOverlay').hidden=false;
 assert(w.OMSWidgetNavigation.back());assert(!dialog.open);assert(!w.document.getElementById('detailOverlay').hidden);assert(w.OMSWidgetNavigation.back());
 await w.OMSMissionTasks.privateAction(session,'complete',{id});assert(calls.some(c=>c[0]==='refresh'));
 dom.window.close();
 const absent=setup();absent.w.OMSWidgetNavigation.ready(session,[],()=>assert.fail());assert(absent.w.document.getElementById('message').textContent.includes('볼 수 없습니다'));absent.dom.window.close();
 for(const [url,native]of [['https://omgworks24.com/mission.html',true],['https://omgworks24.com/mission.html?app=todo',false]]){const env=setup(url,native);assert(!env.w.OMSWidgetNavigation);env.dom.window.close();}
 console.log('PASS widget task deep link, one-shot opening, detail/list/launcher back, modal precedence, unavailable target, refresh and ordinary browser isolation');
})().catch(e=>{console.error(e);process.exitCode=1});
