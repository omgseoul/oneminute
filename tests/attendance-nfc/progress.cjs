const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const read=file=>fs.readFileSync(file,'utf8');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const errors=[];
  for(const width of [320,360,412,520]){
   const page=await browser.newPage({viewport:{width,height:950}});page.on('pageerror',e=>errors.push(e.message));
   const unwantedNavigation=[];
   await page.route('**/*',r=>{if(r.request().isNavigationRequest()&&r.request().url().includes('report.html'))unwantedNavigation.push(r.request().url());return r.abort();});
   await page.route('https://omgworks24.com/app.html',r=>r.fulfill({contentType:'text/html',body:'<body></body>'}));
   await page.goto('https://omgworks24.com/app.html');
   const html=read('app.html').replace(/<script[\s\S]*?<\/script>/g,'').replace(/<link[^>]*>/g,'').replace('class="omg-booting"','class=""');
   await page.setContent('<base href="https://omgworks24.com/">'+html);
   await page.evaluate(()=>{window.OMGNative={};});
   await page.addScriptTag({content:read('page-transition.js')});
   await page.addStyleTag({content:read('top-layout.css')+read('action-dialog.css')+read('attendance-flow.css')});
   await page.addScriptTag({content:read('attendance-flow.js')});
   await page.evaluate(()=>{
    document.getElementById('appShell').classList.add('ready','staff-attendance-shell');document.getElementById('mainMenu').inert=false;
    const old=document.getElementById('workerStatus'),flow=document.createElement('ol');flow.id='workerStatus';old.replaceWith(flow);flow.closest('.top').classList.add('staff-attendance-top');document.getElementById('myInfoQuick').style.display='inline-flex';
    window.session={employeeName:'변지훈',status:'working'};window.state={basis:'nfc',status:'working',entry_at:null,checkin_report_at:null};
    window.paint=()=>{OMSAttendanceFlow.renderProgress(flow,state,session);OMSAttendanceFlow.renderHeading(document.getElementById('workingHeading'),state,session);};paint();
    window.navigation=[];OMSAttendanceFlow.bindCheckin(document.querySelector('#reportMenu a'),{refresh:async()=>state,stop(){}},url=>navigation.push(url));
   });
   for(const basis of ['nfc','first_login','report']){
    await page.evaluate(basis=>{state.basis=basis;paint();},basis);
    const labels=await page.locator('.attendance-progress-label').allTextContents();
    assert.deepEqual(labels,[basis==='nfc'?'도착':'로그인','출근보고','근무중','퇴근보고']);
    const layout=await page.evaluate(()=>{
     const labels=[...document.querySelectorAll('.attendance-progress-label')].map(el=>{const r=document.createRange();r.selectNodeContents(el);const b=r.getBoundingClientRect();return {left:b.left,right:b.right};});
     return {labels,actions:document.querySelector('.top-actions').getBoundingClientRect().left,overflow:document.documentElement.scrollWidth>innerWidth};
    });
    assert(layout.labels[0].left>=0&&layout.actions<width,`${width} header fits viewport`);
    for(let i=1;i<4;i++)assert(layout.labels[i-1].right<=layout.labels[i].left,`${width}/${basis} labels do not overlap`);
    assert(layout.labels[3].right<=layout.actions,`${width}/${basis} actions do not overlap`);
   }
   await page.evaluate(()=>{state.basis='nfc';paint();});
   assert.equal(await page.locator('.attendance-progress .is-current,.attendance-progress .is-done').count(),0,'untagged NFC is entirely grey');
   assert((await page.locator('#workingHeading').textContent()).endsWith(' 로그인'));
   assert.equal(await page.locator('#appShell').evaluate(el=>getComputedStyle(el).paddingTop),'28px');
   const link=page.locator('#reportMenu a').first();await link.click();
   await page.getByRole('heading',{name:'NFC 태그를 해주십시오',exact:true}).waitFor();
   if(width===320){await page.waitForTimeout(2200);assert.deepEqual(unwantedNavigation,[]);assert.equal(await page.locator('dialog[open]').count(),1);assert.equal(await page.evaluate(()=>navigation.length),0);}
   await page.getByRole('button',{name:'확인',exact:true}).click();if(width===320){await page.waitForTimeout(2200);assert.deepEqual(unwantedNavigation,[]);}assert.equal(await page.evaluate(()=>navigation.length),0);
   await link.click();await page.getByRole('button',{name:'무시하고 메뉴보기',exact:true}).click();await page.waitForFunction(()=>navigation.length===1);assert.equal(await page.evaluate(()=>navigation.length),1);
   await page.evaluate(()=>{state.entry_at='2026-10-24T00:00:00Z';paint();});await link.click();await page.waitForFunction(()=>navigation.length===2);assert.equal(await page.evaluate(()=>navigation.length),2);assert.equal(await page.locator('dialog[open]').count(),0);
   assert.equal(await page.locator('.attendance-progress [aria-current=step]').textContent(),'도착');
   assert.equal(await page.locator('#workingHeading .online-dot.reported').count(),0);
   await page.evaluate(()=>{state.checkin_report_at='2026-10-24T00:01:00Z';paint();});assert.equal(await page.locator('#workingHeading .online-dot.reported').count(),1);assert.equal(await page.locator('.attendance-progress [aria-current="step"]').textContent(),'근무중');
   assert((await page.locator('#workingHeading').textContent()).endsWith(' 근무중'));
   const colors=await page.locator('.attendance-progress .is-done .attendance-progress-dot,.attendance-progress .is-current .attendance-progress-dot').evaluateAll(els=>els.map(el=>getComputedStyle(el).backgroundColor));assert(colors.every(color=>color==='rgb(45, 113, 189)'));
   if(width===412)await page.screenshot({path:'/workspace/scratch/399d827ad8cf/attendance-progress-home.png'});
   await page.evaluate(()=>{state.status='completed';paint();});assert.equal(await page.locator('.attendance-progress .is-done').count(),4);
   await page.close();
  }
  // Execute the real report page and session submit flow with isolated transports.
  const page=await browser.newPage({viewport:{width:360,height:850}});page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
   const session={sessionKind:'staff',employeeName:'변지훈',accessToken:'fixture',status:'working',timezone:'Asia/Seoul',clockInAt:'2026-10-24T00:00:00Z'};
   window.omgSession={require:async()=>session,get:()=>session,logout:async()=>{}};window.omgTransition={ready(){document.documentElement.classList.remove('omg-booting');}};
   window.omgWorkConfig={load:async()=>({property:{name:'테스트 지점',room_types:[]},report_config:{clock_in:[],clock_out:[],reminder_cards:[]}}),orderedFields:()=>[],fieldsFor:()=>[]};window.OMSHousingRooms={housesFor:()=>[]};
   window.OMG_SUPABASE={url:'https://example.test',publishableKey:'fixture'};window.saved=[];window.failSave=false;
   window.omgSupabase={rpc:async(name,args)=>{
    if(name==='get_work_report')return {data:{ok:false,code:'not_found'}};
    if(name==='attendance_nfc_entry')return {data:{ok:true,basis:'nfc',entry_at:null,status:'working'}};
    if(name==='save_work_report'){if(failSave)return {data:{ok:false,message:'테스트 저장 실패'}};saved.push(args.p_payload);return {data:{ok:true,report_id:'fixture',already_saved:false,make_accepted:true,payload:args.p_payload}};}
    throw Error('Unexpected RPC '+name);
   }};window.fetch=async()=>({ok:true,json:async()=>({ok:true})});
  });
  const scripts=new Set(['attendance-nfc.js','attendance-flow.js','report-session.js']);
  const report=read('report.html').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(_,url)=>scripts.has(url.split('?')[0])?'<script>'+read(url.split('?')[0])+'</script>':'').replace(/<link[^>]*>/g,'').replace('</head>','<style>'+read('action-dialog.css')+read('attendance-flow.css')+'</style></head>');
  await page.route('**/*',route=>route.fulfill({contentType:'text/html',body:route.request().url().includes('report.html')?report:'<p>메인</p>'}));
  await page.goto('https://fixture.test/report.html?type=clock_in');await page.getByRole('button',{name:'출근보고 제출',exact:true}).waitFor();
  assert.equal(await page.locator('.attendance-nfc-worker').count(),0);assert.equal(await page.locator('#clockInTime').textContent(),'');
  await page.evaluate(()=>failSave=true);await page.getByRole('button',{name:'출근보고 제출',exact:true}).click();await page.getByText('테스트 저장 실패').first().waitFor();assert.equal(await page.locator('dialog[open]').count(),0);
  await page.evaluate(()=>failSave=false);await page.getByRole('button',{name:'출근보고 제출',exact:true}).click();await page.getByRole('heading',{name:'출근완료',exact:true}).waitFor();
  assert.equal(await page.locator('#donePage').isVisible(),false);const saved=await page.evaluate(()=>saved);assert.equal(saved.length,1);assert(!('watch_test_requested' in saved[0]));assert(!('watch_test_after_minutes' in saved[0]));
  await page.screenshot({path:'/workspace/scratch/399d827ad8cf/attendance-progress-complete.png'});
  await page.getByRole('button',{name:'확인',exact:true}).click();await page.waitForURL('**/app.html');
  assert.deepEqual(errors,[]);await page.close();
  console.log('PASS: 320–520px actual home layout, basis labels, status dots, both NFC dialog actions, tagged entry, completion, real report submit/failure, no NFC cards or watch request');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
