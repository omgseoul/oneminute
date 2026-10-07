const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{JSDOM}=require('jsdom');
const html=fs.readFileSync('attendance.html','utf8');
const tick=()=>new Promise(r=>setTimeout(r,10));
test('payroll entry, employee form, saved values, selected branches and errors',async()=>{
 const dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/attendance.html',runScripts:'outside-only'}),w=dom.window;
 const calls=[];let ids=['p1'],fail=false,deferred=null;
 const employee={employee_id:'e1',property_id:'p1',display_name:'직원 <A>',property_name:'서울역',active:true,pay_type:'hourly',hourly_rate:12000,monthly_salary:null,cycle_start_day:1,pay_day:null,pay_month_offset:1,work_minutes:90,work_days:1,missing_count:1,working_count:0,expected_pay:18000,period_start:'2026-10-01',period_end:'2026-10-31',pay_date:null};
 w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});if(deferred){const wait=deferred;deferred=null;await wait;}if(fail)return{error:{message:'offline'}};if(name==='save_employee_payroll')Object.assign(employee,args.p_settings);return{data:{ok:true,employees:[{...employee,property_name:args.p_property_ids?.[0]==='p2'?'종로':'서울역'}]}};}};
 w.eval(fs.readFileSync('payroll.js','utf8'));
 const control=w.OMSPayroll.init({accessToken:'test-token',getPropertyIds:()=>ids});
 const button=w.document.getElementById('openPayroll'),host=w.document.getElementById('payrollView');
 assert.equal(button.hidden,false);button.click();await tick();assert.equal(control.isActive(),true);assert.equal(w.document.getElementById('attendanceContent').hidden,true);
 assert.deepEqual(calls[0].args.p_property_ids,['p1']);assert.equal(host.querySelector('summary strong').textContent,'직원 <A>');assert.equal(host.querySelector('summary a'),null);
 assert.match(host.querySelector('.payroll-results').textContent,/18,000원/);assert.match(host.querySelector('.payroll-results').textContent,/미기록 1건/);
 const form=host.querySelector('form');form.elements.cycle_start_day.value='26';form.elements.cycle_start_day.dispatchEvent(new w.Event('change'));assert.equal(form.querySelector('.cycle-end').textContent,'~ 다음 달 25일');
 form.elements.pay_day.value='10';form.elements.pay_type.value='monthly';form.elements.monthly_salary.value='2400000';form.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();
 const saved=calls.find(x=>x.name==='save_employee_payroll').args;assert.equal(saved.p_settings.monthly_salary,2400000);assert.equal(saved.p_settings.cycle_start_day,26);assert.equal(saved.p_settings.pay_day,10);assert.equal(saved.p_employee_id,'e1');assert.match(form.querySelector('.payroll-status').textContent,/저장되었습니다/);
 ids=['p2'];await control.refresh();assert.equal(host.querySelector('summary small').textContent,'종로');assert.deepEqual(calls.at(-1).args.p_property_ids,['p2']);
 host.querySelector('input[type=month]').value='2026-12';host.querySelector('[data-step="1"]').click();await tick();assert.equal(calls.at(-1).args.p_month,'2027-01-01');
 fail=true;await control.refresh();assert.equal(host.querySelectorAll('form').length,0);assert.equal(host.querySelector('.payroll-results').textContent,'');assert.match(host.querySelector('[role=alert]').textContent,/다시 시도/);
 fail=false;let resolve;deferred=new Promise(r=>resolve=r);const pending=control.refresh();host.querySelector('.payroll-back').click();resolve();await pending;assert.equal(control.isActive(),false);assert.equal(host.hidden,true);assert.equal(w.document.getElementById('attendanceContent').hidden,false);assert.equal(w.document.getElementById('pageTitle').textContent,'근태관리');
 w.close();
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
