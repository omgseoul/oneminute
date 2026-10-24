// Execute app.html's actual startup script; helpers alone cannot catch broken wiring.
const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const read=file=>fs.readFileSync(file,'utf8');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  for(const scenario of ['nfc','tagged','reported','first_login','owner']){
   const page=await browser.newPage({viewport:{width:360,height:850}}),errors=[];
   page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error'&&message.text().includes('Home initialization failed'))errors.push(message.text());});
   await page.addInitScript(scenario=>{
    const owner=scenario==='owner';
    const session={sessionKind:owner?'owner':'staff',employeeName:'테스트 근무자',employeeId:'worker-a',ownerId:owner?'owner-a':null,propertyId:'property-a',accessToken:'fixture',status:'working',timezone:'Asia/Seoul'};
    window.omgSession={require:async()=>session,get:()=>session,logout:async()=>{}};
    window.omgWorkConfig={load:async()=>({can_manage:owner,property:{name:'테스트 지점',property_id:'property-a',management_number:1}})};
    const picker={selectedIds:()=>['property-a']};window.omgPropertySelector={mount:async()=>picker,mountStatic:()=>picker};
    window.GuestSupport={call:async()=>({rooms:[]})};window.OMGNative={};window.rpcCalls=[];
    window.omgSupabase={rpc:async(name,args)=>{
     rpcCalls.push(name);
     if(name==='attendance_nfc_entry')return {data:{ok:true,basis:scenario==='first_login'?'first_login':'nfc',status:'working',entry_at:['tagged','reported'].includes(scenario)?'2026-10-24T00:00:00Z':null,checkin_report_at:scenario==='reported'?'2026-10-24T00:01:00Z':null}};
     if(name==='is_platform_administrator')return {data:false};
     if(name==='list_working_employees')return {data:{ok:true,own_property_id:'property-a',own_property_name:'테스트 지점',employees:[{employee_id:'worker-b',display_name:'동료',property_id:'property-a',property_name:'테스트 지점'}]}};
     if(name==='list_property_messages')return {data:{ok:true,can_manage:owner,messages:[],unread_count:2}};
     if(name==='work_report_inbox')return {data:{ok:true,unread_count:0,reports:[]}};
     if(name==='list_property_shares')return {data:{ok:true,properties:[{property_id:'property-a',is_own:true}]}};
     if(['list_missions','list_shared_missions'].includes(name))return {data:{ok:true,missions:[]}};
     if(name==='calendar_event_action')return {data:{ok:true,events:[]}};
     throw Error('Unexpected RPC '+name);
    }};
   },scenario);
   const scripts=new Set(['page-transition.js','attendance-nfc.js','attendance-flow.js','worker-tasks.js','home-guest-count.js']);
   const html=read(process.env.HOME_TEST_HTML||'app.html').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(_,url)=>scripts.has(url.split('?')[0])?'<script>'+read(url.split('?')[0])+'</script>':'');
   await page.route('**/*',route=>{
    const url=new URL(route.request().url()),file=url.pathname.slice(1);
    if(file==='app.html')return route.fulfill({contentType:'text/html',body:html});
    if(file==='report.html')return route.fulfill({contentType:'text/html',body:'<h1>출근보고 페이지</h1>'});
    if(!file.includes('..')&&fs.existsSync(file)&&fs.statSync(file).isFile())return route.fulfill({path:file});
    return route.fulfill({status:204,body:''});
   });
   await page.goto('https://omgworks24.com/app.html');
   await page.waitForFunction(()=>document.querySelector('#appShell.ready'));
   assert.deepEqual(errors,[],scenario+' must finish actual Home initialization');
   await page.waitForFunction(()=>document.querySelector('#todayOverviewItems').textContent.includes('오늘 일정이 없습니다.')&&document.querySelector('#workingGrid').textContent.includes('동료')&&document.querySelector('#messageCounter').textContent==='2');
   assert.equal(await page.locator('#mainMenu').evaluate(el=>el.inert),false);
   if(scenario!=='owner'){
    assert.equal(await page.locator('.attendance-progress-label').count(),4);
    assert.equal(await page.locator('#myInfoQuick').isVisible(),true);assert.equal(await page.locator('#staffWorkStatus').isVisible(),true);
    assert((await page.locator('#workingHeading').textContent()).endsWith(scenario==='reported'?' 근무중':' 로그인'));
   }
   if(scenario==='nfc'){
    assert.equal(await page.locator('.attendance-progress .is-current,.attendance-progress .is-done').count(),0);
    await page.locator('#reportMenu a').first().click();await page.locator('dialog[open]').waitFor();
    await page.waitForTimeout(1800);assert(page.url().endsWith('/app.html'));
    await page.getByRole('button',{name:'확인',exact:true}).click();await page.waitForTimeout(1800);assert(page.url().endsWith('/app.html'));assert.equal(await page.locator('dialog[open]').count(),0);
    await page.locator('#reportMenu a').first().click();await page.getByRole('button',{name:'무시하고 메뉴보기',exact:true}).click();await page.waitForURL('**/report.html?type=clock_in');
   }
   assert.deepEqual(errors,[],scenario);console.log('PASS actual Home bootstrap: '+scenario);await page.close();
  }
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
