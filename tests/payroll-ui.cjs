const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{JSDOM}=require('jsdom');
const html=fs.readFileSync('attendance.html','utf8');
const tick=()=>new Promise(r=>setTimeout(r,10));
test('payroll overview collapses rows, scopes branches and validates custom dates',async()=>{
 const dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/attendance.html',runScripts:'outside-only'}),w=dom.window;
 const calls=[];let ids=['p1'],fail=false;
 const employee={employee_id:'e1',property_id:'p1',display_name:'직원 A',property_name:'본점',pay_type:'hourly',hourly_rate:12000,work_minutes:90,work_days:1,expected_pay:18000,period_start:'2026-10-01',period_end:'2026-10-31'};
 w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});return fail?{error:{message:'offline'}}:{data:{ok:true,employees:[employee,{...employee,employee_id:'e2',property_id:'p2',property_name:'타지점'}]}};}};
 w.eval(fs.readFileSync('payroll.js','utf8'));const control=w.OMSPayroll.init({accessToken:'token',getPropertyIds:()=>ids,ownPropertyId:'p1'});w.document.getElementById('openPayroll').click();await tick();const host=w.document.getElementById('payrollView');
 assert.equal(host.querySelectorAll('form').length,0);assert.equal(host.querySelector('.payroll-detail').hidden,true);assert.equal(host.querySelectorAll('.payroll-person-name small').length,1);assert.match(host.querySelectorAll('.payroll-row')[0].textContent,/직원 A.*1시간 30분.*18,000원/);
 host.querySelector('.payroll-row').click();assert.equal(host.querySelector('.payroll-detail').hidden,false);
 host.querySelector('[data-mode=range]').click();await tick();assert.equal(calls.at(-1).name,'list_employee_payroll_range');
 host.querySelector('.payroll-from').value='2026-10-20';host.querySelector('.payroll-to').value='2026-10-10';host.querySelector('.payroll-to').dispatchEvent(new w.Event('change'));await tick();assert.match(host.querySelector('.payroll-message').textContent,/시작일/);
 host.querySelector('.payroll-to').value='2026-10-25';ids=['p2'];await control.refresh();assert.deepEqual(calls.at(-1).args.p_property_ids,['p2']);assert.equal(calls.at(-1).args.p_from_date,'2026-10-20');
 fail=true;await control.refresh();assert.equal(host.querySelectorAll('.payroll-row').length,0);assert.match(host.querySelector('.payroll-message').textContent,/다시 시도/);host.querySelector('.payroll-back').click();assert.equal(control.isActive(),false);w.close();
});
test('actual attendance initialization only exposes payroll to owners and retains branch filtering',async()=>{
 for(const owner of [true,false]){
  const dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/attendance.html',runScripts:'outside-only'}),w=dom.window;let change;const calls=[];
  w.omgSession={require:async()=>({sessionKind:owner?'owner':'worker',accessToken:'token',employeeId:'e'})};w.omgWorkConfig={load:async()=>({can_manage:owner,property:{property_id:'p'}})};w.HolidayRequest={init(){}};w.omgTransition={ready(){}};
  w.omgPropertySelector={mount:async x=>{change=x.onChange;return{selectedIds:()=>['p2']};},mountMulti:()=>({})};w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});return{data:{ok:true,sessions:[],employees:[],timezone:'Asia/Seoul'}};}};
  for(const file of ['payroll.js','attendance-summary.js'])w.eval(fs.readFileSync(file,'utf8'));
  for(const m of html.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/g))if(!/\bsrc=/.test(m[1]||''))w.eval(m[2]);
  await tick();const button=w.document.getElementById('openPayroll');assert.equal(button.hidden,!owner);
  if(owner){button.click();await tick();assert.deepEqual(calls.at(-1).args.p_property_ids,['p2']);await change(['p3']);assert.equal(calls.at(-1).name,'list_employee_payroll');assert.deepEqual(calls.at(-1).args.p_property_ids,['p3']);w.document.querySelector('.payroll-back').click();await tick();assert.equal(calls.at(-1).name,'list_shared_attendance_statistics');assert.deepEqual(calls.at(-1).args.p_property_ids,['p3']);}
  w.close();
 }
});
