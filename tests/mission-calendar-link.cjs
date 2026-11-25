const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
(async()=>{
 for(const native of [false,true])for(const mine of [false,true]){
  const id=mine?'personal':'shared',dom=new JSDOM(fs.readFileSync('mission.html','utf8'),{url:`https://omgworks24.com/mission.html?app=calendar-todo&task=${id}${mine?'&scope=mine':''}`,runScripts:'outside-only'}),w=dom.window,calls=[];
  const session={sessionKind:'owner',ownerId:'owner',propertyId:'one',accessToken:'fixture'};
  w.omgSession={require:async()=>session};w.omgWorkConfig={load:async()=>({can_manage:true,property:{property_id:'one'},employees:[]})};w.omgTransition={ready(){}};
  w.omgSelectPicker={mount:()=>({refresh(){}})};w.OMSTargetPicker={mount:()=>({destroy(){}})};w.omgPropertySelector={mount:async()=>({selectedIds:()=>['one','two']}),mountSingle:()=>({value:()=>'',setItems(){}})};
  const shared={id:'shared',title:'다른 지점 공동 업무',property_id:'two',property_name:'OMG House',timing:'today',priority:'normal'},personal={id:'personal',title:'개인 업무',private_owner_id:'owner',kind:'task',property_id:'one',timing:'today',priority:'important'};
  w.omgSupabase={rpc:async(name)=>{calls.push(name);return{data:name==='list_shared_missions'?{ok:true,missions:[shared],employees:[]}:name==='calendar_private_items_action'?{ok:true,items:[personal]}:{ok:true}};}};
  if(native)w.OMSCalendarAndroid={setSession(){},refreshWidgets(){},exitToLauncher(){}};
  w.eval(fs.readFileSync('worker-tasks.js','utf8'));w.eval(fs.readFileSync('mission-widget.js','utf8'));w.eval([...w.document.scripts].findLast(s=>!s.src).textContent);
  await new Promise(r=>setTimeout(r,35));
  assert(calls.includes('list_shared_missions'),'calendar links must not enter private-widget-only query');
  assert.equal(w.OMSWidgetNavigation.privateOnly,false);
  assert.equal(w.document.getElementById('detailOverlay').hidden,false,w.document.getElementById('message').textContent);
  assert.equal(w.document.getElementById('detailHeading').textContent,mine?personal.title:shared.title);
  assert.equal(w.location.search.includes('task='),false);assert(w.OMSWidgetNavigation.back());assert(w.document.getElementById('detailOverlay').hidden);assert(!w.OMSWidgetNavigation.back());
  w.close();
 }
 console.log('PASS actual To do boot opens personal and shared branch task details in native and browser calendar routes; Back closes details to list');
})().catch(e=>{console.error(e);process.exitCode=1});
