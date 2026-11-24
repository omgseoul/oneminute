const fs=require('fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const read=f=>fs.readFileSync(f,'utf8');
(async()=>{const browser=await chromium.launch();try{const errors=[];
 for(const width of [320,360,412]){
  const p=await browser.newPage({viewport:{width,height:740}});p.on('pageerror',e=>errors.push(e.message));
  await p.setContent('<html lang="ko"><body style="font-family:sans-serif"><a id="report" href="report.html?type=clock_in">출근보고</a></body></html>');
  for(const f of ['action-dialog.css','attendance-flow.css'])await p.addStyleTag({path:f});await p.addScriptTag({path:'attendance-flow.js'});
  await p.evaluate(()=>{window.omgSession={get:()=>({timezone:'Asia/Seoul'})};window.entries=[];window.choices=[];window.opened=[];OMSAttendanceFlow.bindCheckin(document.querySelector('a'),{refresh:async()=>({basis:'nfc',status:'working',nfc_entries:entries}),select:async id=>choices.push(id),stop(){}},url=>opened.push(url));});
  await p.click('a');await p.getByRole('heading',{name:'새로 NFC 태그해주세요',exact:true}).waitFor();assert.equal(await p.locator('dialog button').count(),1);await p.getByRole('button',{name:'확인',exact:true}).click();assert.equal(await p.evaluate(()=>opened.length),0);
  await p.evaluate(()=>entries=[{id:'first',recorded_at:'2026-11-24T00:00:00Z'},{id:'second',recorded_at:'2026-11-24T00:15:00Z'}]);await p.click('a');await p.locator('.nfc-time-dialog').waitFor();assert.equal(await p.evaluate(()=>opened.length),0);assert(await p.locator('[data-confirm]').isDisabled());const rect=await p.locator('dialog').boundingBox();assert(rect.x>=0&&rect.x+rect.width<=width);await p.screenshot({path:'/tmp/nfc-selection-'+width+'.png'});
  await p.locator('input[value=second]').check();await p.locator('[data-confirm]').click();await p.waitForFunction(()=>opened.length===1);assert.deepEqual(await p.evaluate(()=>choices),['second']);await p.close();
 }
  // Execute the real report page and session submit flow with isolated transports.
  const page=await browser.newPage({viewport:{width:360,height:850}});page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
   const session={sessionKind:'staff',employeeName:'변지훈',accessToken:'fixture',status:'working',timezone:'Asia/Seoul',clockInAt:'2026-10-24T00:00:00Z'};
   window.omgSession={require:async()=>session,get:()=>session,logout:async()=>{}};window.omgTransition={ready(){document.documentElement.classList.remove('omg-booting');}};
   window.omgWorkConfig={load:async()=>({property:{name:'테스트 지점',room_types:[]},report_config:{clock_in:[],clock_out:[],reminder_cards:[]}}),orderedFields:()=>[],fieldsFor:()=>[]};window.OMSHousingRooms={housesFor:()=>[]};
   window.OMG_SUPABASE={url:'https://example.test',publishableKey:'fixture'};window.saved=[];window.failSave=false;window.EmployeeProfileWarning={show:async()=>false};
   window.omgSupabase={rpc:async(name,args)=>{
    if(name==='get_work_report')return {data:{ok:false,code:'not_found'}};
    if(name==='attendance_nfc_entry')return {data:{ok:true,basis:'nfc',entry_at:'2026-10-24T00:15:00Z',selected_entry_id:'entry',status:'working'}};
    if(name==='save_work_report'){if(failSave)return {data:{ok:false,message:'테스트 저장 실패'}};saved.push(args.p_payload);return {data:{ok:true,report_id:'fixture',already_saved:false,make_accepted:true,payload:args.p_payload}};}
    throw Error('Unexpected RPC '+name);
   }};window.fetch=async()=>({ok:true,json:async()=>({ok:true})});
  });
  const scripts=new Set(['attendance-nfc.js','attendance-flow.js','report-session.js']);
  const report=read('report.html').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(_,url)=>scripts.has(url.split('?')[0])?'<script>'+read(url.split('?')[0])+'</script>':'').replace(/<link[^>]*>/g,'').replace('</head>','<style>'+read('action-dialog.css')+read('attendance-flow.css')+'</style></head>');
  await page.route('**/*',route=>route.fulfill({contentType:'text/html',body:route.request().url().includes('report.html')?report:'<p>메인</p>'}));
  await page.goto('https://fixture.test/report.html?type=clock_in');await page.getByRole('button',{name:'출근보고 제출',exact:true}).waitFor();
  assert.equal(await page.locator('.attendance-nfc-worker').count(),0);assert((await page.locator('#clockInTime').textContent()).includes('9:15:00'));assert.equal(await page.locator('.nfc-time-dialog').count(),0);
  await page.evaluate(()=>failSave=true);await page.getByRole('button',{name:'출근보고 제출',exact:true}).click();await page.getByText('테스트 저장 실패').first().waitFor();assert.equal(await page.locator('dialog[open]').count(),0);
  await page.evaluate(()=>failSave=false);await page.getByRole('button',{name:'출근보고 제출',exact:true}).click();await page.getByRole('heading',{name:'출근 완료',exact:true}).waitFor();
  assert.equal(await page.locator('#donePage').isVisible(),false);const saved=await page.evaluate(()=>saved);assert.equal(saved.length,1);assert(!('watch_test_requested' in saved[0]));assert(!('watch_test_after_minutes' in saved[0]));
  await page.screenshot({path:'/tmp/nfc-selection-complete.png'});
  await page.getByRole('button',{name:'확인',exact:true}).click();await page.waitForURL('**/app.html');
  assert.deepEqual(errors,[]);await page.close();console.log('PASS 320/360/412px menu NFC selection and real report: selected time shown, completion has no time picker');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
