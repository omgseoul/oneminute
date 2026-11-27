const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  for(const width of [320,360,412,800]){
   const page=await browser.newPage({viewport:{width,height:840}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.route('https://oms.test/**',r=>{const url=new URL(r.request().url()),name=url.pathname.slice(1);try{let body=fs.readFileSync(name);if(name.endsWith('.html'))body=body.toString().replace(/<script[\s\S]*?<\/script>/g,'');return r.fulfill({body,contentType:name.endsWith('.css')?'text/css':'text/html'});}catch{return r.fulfill({status:404,body:''});}});
   await page.goto('https://oms.test/calendar.html?app=calendar');
   await page.evaluate(()=>{
    Date.now=()=>Date.parse('2026-11-25T01:00:00Z');
    const owner='owner',home='one';window.calendarCalls=[];
    const events=[{id:'event-a',title:'객실 점검',all_day:false,start_at:'2026-11-25T01:00:00Z',end_at:'2026-11-25T02:00:00Z',owner_target:true,property_id:home,can_edit:true},{id:'event-b',title:'직원 미팅',start_at:'2026-11-25T05:00:00Z',end_at:'2026-11-25T06:00:00Z',owner_target:true,property_id:home,can_edit:true},{id:'overnight',title:'야간 점검',start_at:'2026-11-24T14:00:00Z',end_at:'2026-11-24T16:00:00Z',owner_target:true,property_id:home,can_edit:true}];
    const tasks=[{id:'task-a',title:'연남동 사업자 확인',due_at:'2026-11-25T14:59:00Z',priority:'important',private_owner_id:owner,kind:'task',property_id:home},{id:'task-b',title:'비자 마무리',timing:'today',private_owner_id:owner,kind:'task',property_id:home},{id:'shared-task',title:'공동 업무',timing:'today',kind:'task',property_id:home}];
    window.omgSession={require:async()=>({sessionKind:'owner',ownerId:owner,propertyId:home,accessToken:'fixture',timezone:'Asia/Seoul'})};
    window.omgTransition={ready(){document.documentElement.classList.remove('omg-booting')}};
    window.OMSCalendarAndroid={};window.OMSCalendarCompanion={session(){},settings(){window.settingsOpened=true;}};
    window.OMSTargetPicker={load:async()=>({people:[],properties:[]}),mount:()=>({destroy(){},setDisabled(){}})};
    window.omgWorkConfig={load:async()=>({property:{property_id:home}})};
    window.OMSWorkerTasks={events:x=>x};window.OMSMissionTasks={load:async()=>({missions:tasks.filter(t=>!t.private_owner_id)}),pending:x=>x,privateAction:async()=>({items:tasks.filter(t=>t.private_owner_id)}),section:()=>'',propertyTag:()=>''};
    window.omgSupabase={rpc:async(name,args)=>{calendarCalls.push({name,args});return {data:name==='list_property_shares'?{ok:true,properties:[{property_id:home,property_name:'One Minute',is_own:true},{property_id:'two',property_name:'OMG House',permissions:['missions']}]}:{ok:true,events,tasks:[],employees:[]}};}};
   });
   await page.addScriptTag({path:'property-selector.js'});await page.addScriptTag({path:'calendar.js'});
   await page.waitForSelector('.calendar-month');
   const top=await page.locator('.calendar-top').evaluate(el=>[...el.children].filter(x=>!x.hidden).map(x=>({top:x.getBoundingClientRect().top,bottom:x.getBoundingClientRect().bottom,right:x.getBoundingClientRect().right})));
   assert(top.every(r=>Math.abs(r.top-top[0].top)<9),`same header row ${width}: ${JSON.stringify(top)}`);
   assert.deepEqual(await page.locator('.calendar-top').evaluate(el=>[...el.children].filter(x=>!x.hidden).map(x=>x.id||'title')),['title','companionControls','calendarPropertyPicker','companionSettings']);
   const controls=await page.locator('#companionScope,#calendarPropertyPicker .property-picker-button,#companionSettings').evaluateAll(els=>els.map(el=>{const r=el.getBoundingClientRect();return {top:r.top,height:r.height};}));
   assert(controls.every(r=>r.height===36&&Math.abs(r.top-controls[0].top)<1),'equal filter and settings heights/alignment '+JSON.stringify(controls));
   assert.equal(await page.locator('#companionTasks .companion-task-icon').first().textContent(),'');
   assert(top.every(r=>r.right<=width),`header fits ${width}`);
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal overflow');
   assert.equal(await page.locator('#viewButtons svg').count(),3);assert.equal(await page.locator('#companionDate').count(),0);
   assert.equal(await page.locator('#companionTasks [data-id=task-a]').count(),1);assert.equal(await page.locator('#companionTasks .companion-priority').count(),1);
   await page.locator('.calendar-day[data-date="2026-11-26"] .calendar-day-number').click();await page.waitForSelector('#eventDialog[open]');assert.equal(await page.locator('#eventDate').inputValue(),'2026-11-26');await page.keyboard.press('Escape');assert.equal(await page.locator('#companionEventCount').textContent(),'0');
   await page.locator('.calendar-day[data-date="2026-11-25"] .calendar-day-number').click();
   await page.waitForSelector('#eventDialog[open]');await page.keyboard.press('Escape');
   assert.equal(await page.locator('#companionEventCount').textContent(),'3');
   const positions=await page.locator('#calendarCompanion').evaluate(el=>[el.querySelector('#companionEvents').getBoundingClientRect().top,el.querySelector('#companionTasks').getBoundingClientRect().top]);assert(positions[0]<positions[1]);
   await page.locator('#showCalendarTasks').uncheck();assert.equal(await page.locator('#calendarBoard [data-kind=task]').count(),0);assert.equal(await page.locator('#companionTasks [data-kind=task]').count(),2);
   await page.locator('#showCalendarTasks').check();await page.locator('#showCalendarEvents').uncheck();assert.equal(await page.locator('#calendarBoard [data-kind=event]').count(),0);await page.locator('#showCalendarEvents').check();
   await page.screenshot({path:`/tmp/calendar-clean-${width}.png`,fullPage:true});
   await page.locator('[data-view=week]').click();await page.waitForSelector('.companion-week-column');
   assert.equal(await page.locator('.companion-week-column').count(),7);assert.equal(await page.locator('.companion-week-date').first().getAttribute('data-date'),'2026-11-22');
   assert.equal(await page.locator('.companion-week-date').last().getAttribute('data-date'),'2026-11-28');
   assert.equal(await page.locator('.companion-week-column [data-id=overnight]').count(),2,'overnight event split across both dates');
   assert((await page.locator('.companion-week-scroll').evaluate(el=>el.scrollHeight>el.clientHeight)),'all 24 hours accessible');
   await page.screenshot({path:`/tmp/calendar-week-${width}.png`,fullPage:true});
   await page.locator('#nextButton').click();await page.waitForFunction(()=>document.querySelector('.companion-week-date')?.dataset.date==='2026-11-29');
   await page.locator('#todayButton').click();await page.waitForFunction(()=>document.querySelector('.companion-week-date')?.dataset.date==='2026-11-22');
   await page.locator('#companionScope').selectOption('all');await page.waitForFunction(()=>document.querySelectorAll('#companionTasks [data-kind=task]').length===3);await page.locator('#companionScope').selectOption('mine');await page.waitForFunction(()=>document.querySelectorAll('#companionTasks [data-kind=task]').length===2);
   await page.locator('[data-view=day]').click();await page.waitForSelector('.calendar-day-view');
   await page.locator('#companionSettings').click();assert(await page.evaluate(()=>settingsOpened));
   assert((await page.locator('#companionTodoLink').getAttribute('href')).includes('app=calendar-todo'));
   await page.locator('#companionTasks [data-id=task-a]').click();await page.waitForURL('**/mission.html?**task=task-a');assert(page.url().includes('scope=mine'));assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS companion 320–800px header, icons, selected-day cards, display toggles, 7-day timeline, overnight events, 24h scroll, navigation, settings and direct To do links');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
