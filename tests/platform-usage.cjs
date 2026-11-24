const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const root=process.cwd();
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.OMS_CHROMIUM_PATH?{executablePath:process.env.OMS_CHROMIUM_PATH}:{})});
 try{
  for(const width of [320,360,1280]){
   const p=await browser.newPage({viewport:{width,height:900}}),errors=[];p.on('pageerror',e=>errors.push(e.message));
   await p.route('**/*',r=>{const u=new URL(r.request().url()),file=path.join(root,u.pathname);if(u.hostname!=='oms.test')return r.abort();try{let body=fs.readFileSync(file);if(u.pathname==='/platform-admin.html')body=body.toString().replace(/<script[\s\S]*?<\/script>/g,'');return r.fulfill({body,contentType:file.endsWith('.css')?'text/css':'text/html'});}catch{return r.fulfill({status:404,body:''});}});
   await p.goto('http://oms.test/platform-admin.html');
   await p.evaluate(()=>{
    const GB=1073741824;
    window.fixture={failAI:false,failStorage:false,failTranslation:false,empty:false,aiCalls:0,translationCalls:0};
    window.dashboard={ok:true,properties:[
     {property_id:'one',management_number:1,property_name:'One Minute',service_status:'active',employee_count:2,service:{used_bytes:GB,limit_bytes:2*GB}},
     {property_id:'two',management_number:2,property_name:'OMG House',service_status:'active',employee_count:2,service:{used_bytes:0,limit_bytes:0}}
    ],policy:{trial_days:30,reminder_days:7,grace_days:3,storage_limit_bytes:2*GB,storage_warning_bytes:GB,end_action:'notice',storage_action:'warn',support_contact:''},plans:[],summary:{total:2,active:2,trial:0},recent_actions:[],last_checked_at:'2026-11-24T13:00:00Z'};
    window.omgAccount={require:async()=>({})};window.omgTransition={ready(){}};window.OMG_SUPABASE={url:'https://api.invalid',publishableKey:'fixture'};
    window.omgSupabase={auth:{getSession:async()=>({data:{session:{access_token:'platform-session'}}})},rpc:async(name)=>{
     if(name==='platform_trial_codes')return {data:{ok:true,codes:[]}};
     if(name==='platform_system_notices')return {data:{ok:true,templates:[],deliveries:[]}};
     if(fixture.failStorage)return {error:{message:'storage offline'}};
     return {data:{...dashboard,properties:fixture.empty?[]:dashboard.properties}};
    }};
    window.GuestAI={call:async(action,data,auth)=>{if(action!=='list'||auth.platform_token!=='platform-session')throw Error('wrong platform request');fixture.aiCalls++;if(fixture.failAI)throw Error('AI offline');return {ok:true,properties:fixture.empty?[]:[{id:'two',name:'OMG House',usage:{used:0,monthly_limit:0,available:0,reserved:0,month:'2026-11-01'}},{id:'one',name:'One Minute',usage:{used:12.345,monthly_limit:1000,available:985.655,reserved:2,month:'2026-11-01'}}]};}};
    window.fetch=async(url,options)=>{const body=JSON.parse(options.body);if(body.action!=='translation_status'||body.platform_token!=='platform-session')throw Error('wrong translation request');fixture.translationCalls++;if(fixture.failTranslation)throw Error('translation offline');return {ok:true,json:async()=>({ok:true,properties:fixture.empty?[]:[{id:'two',name:'OMG House',usage:{used:0,limit:0,remaining:0,personal_used:0,reserved:0,month:'2026-11'}},{id:'one',name:'One Minute',usage:{used:40000,limit:50000,remaining:9500,personal_used:3000,reserved:500,month:'2026-11'}}]})};};
   });
   await p.addScriptTag({path:path.join(root,'platform-usage.js')});await p.addScriptTag({path:path.join(root,'operations-center.js')});
   await p.waitForFunction(()=>document.querySelectorAll('.customer').length===2);
   assert.equal(await p.evaluate(()=>fixture.aiCalls),0,'credits load only when usage is opened');
   await p.click('[data-tab=usage]');await p.waitForFunction(()=>!document.getElementById('usageRefresh').disabled);
   assert.equal(await p.locator('[data-usage-total]').count(),3);
   assert.equal(await p.locator('[data-usage-total=storage] strong').textContent(),'1 GB');
   assert.equal(await p.locator('[data-usage-total=translation] strong').textContent(),'40,000자');
   assert.equal(await p.locator('[data-usage-total=credits] strong').textContent(),'12.345 크레딧');
   const one=p.locator('[data-usage-property=one]'),two=p.locator('[data-usage-property=two]');
   assert((await one.textContent()).includes('사용 가능 985.655 크레딧 · 처리 중 2 크레딧'));
   assert((await one.textContent()).includes('개인 API 3,000자 · 총 번역 43,000자'));
   assert.equal(await two.locator('[data-usage-kind=credits] .usage-value strong').textContent(),'0 크레딧','join on IDs, not response order');
   assert.equal(await two.locator('[data-usage-kind=credits] progress').getAttribute('value'),'0');
   assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'page fits viewport');
   await p.screenshot({path:`/tmp/oms-usage-${width}.png`,fullPage:true});
   await p.evaluate(()=>fixture.failAI=true);await p.click('#usageRefresh');await p.waitForFunction(()=>!document.getElementById('usageRefresh').disabled);
   assert.equal(await p.locator('[data-usage-total=credits] strong').textContent(),'—');assert((await p.locator('#usageStatus').textContent()).includes('AI offline'));
   assert.equal(await p.locator('[data-usage-total=translation] strong').textContent(),'40,000자');
   await p.evaluate(()=>{fixture.failAI=false;fixture.failTranslation=true;fixture.failStorage=true;});await p.click('#usageRefresh');await p.waitForFunction(()=>!document.getElementById('usageRefresh').disabled);
   assert.equal(await p.locator('[data-usage-total=storage] strong').textContent(),'—');assert.equal(await p.locator('[data-usage-total=translation] strong').textContent(),'—');assert.equal(await p.locator('[data-usage-total=credits] strong').textContent(),'12.345 크레딧');
   await p.evaluate(()=>{fixture.failTranslation=false;fixture.failStorage=false;});
   await p.click('#refreshButton');await p.waitForFunction(()=>!document.getElementById('refreshButton').disabled&&!document.getElementById('usageRefresh').disabled);
   assert.equal(await p.locator('[data-usage-total=storage] strong').textContent(),'1 GB','global refresh also refreshes usage');
   await p.evaluate(()=>fixture.empty=true);await p.click('#usageRefresh');await p.waitForFunction(()=>!document.getElementById('usageRefresh').disabled);
   assert.equal(await p.locator('[data-usage-property]').count(),0);assert.equal(await p.locator('[data-usage-total=credits] strong').textContent(),'0 크레딧');assert((await p.locator('#usageList').textContent()).includes('등록된 지점이 없습니다.'));
   assert.deepEqual(errors,[]);await p.close();
  }
  console.log('PASS: three usage categories at 320/360/1280px; ID joins, zero limits, reservations, personal translation, isolated API failures, retry, global refresh and empty data');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
