const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{JSDOM}=require('jsdom');
const html=fs.readFileSync('attendance.html','utf8');
const tick=()=>new Promise(r=>setTimeout(r,10));
test('payroll overview collapses rows, scopes branches and validates custom dates',async()=>{
 const dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/attendance.html',runScripts:'outside-only'}),w=dom.window;
 const calls=[];let ids=['p1','p2'],fail=false;
 const employee={employee_id:'e1',property_id:'p1',display_name:'직원 A',property_name:'본점',pay_type:'hourly',hourly_rate:12000,work_minutes:90,work_days:1,expected_pay:18000,period_start:'2026-10-01',period_end:'2026-10-31'};
 w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});const all=[employee,{...employee,employee_id:'e2',display_name:'직원 B',property_id:'p2',property_name:'타지점',work_minutes:200,expected_pay:100},{...employee,employee_id:'e3',display_name:'직원 C',property_id:'p3',property_name:'신규지점'}];return fail?{error:{message:'offline'}}:{data:{ok:true,employees:all.filter(x=>args.p_property_ids.includes(x.property_id))}};}};
 w.eval(fs.readFileSync('property-selector.js','utf8'));w.eval(fs.readFileSync('payroll.js','utf8'));const control=w.OMSPayroll.init({accessToken:'token',getPropertyIds:()=>ids,ownPropertyId:'p1'});w.document.getElementById('openPayroll').click();await tick();const host=w.document.getElementById('payrollView');
 assert.equal(host.querySelectorAll('form').length,0);assert.equal(host.querySelector('.payroll-detail').hidden,true);assert.equal(host.querySelectorAll('.payroll-person-name small').length,1);assert.match(host.querySelectorAll('.payroll-row')[0].textContent,/직원 A.*1시간 30분.*18,000원/);
 host.querySelector('.payroll-row').click();assert.equal(host.querySelector('.payroll-detail').hidden,false);
 assert.equal(host.querySelectorAll('.payroll-employee-host [data-value]').length,2);host.querySelector('.payroll-employee-host [data-value="e2"]').click();assert.equal(host.querySelectorAll('.payroll-row').length,1);host.querySelector('.payroll-employee-host [data-all]').click();assert.equal(host.querySelectorAll('.payroll-row').length,2);
 host.querySelector('[data-sort=work]').click();assert.match(host.querySelector('.payroll-row').textContent,/직원 B/);host.querySelector('[data-sort=pay]').click();assert.match(host.querySelector('.payroll-row').textContent,/직원 A/);host.querySelector('[data-sort=pay]').click();assert.match(host.querySelector('.payroll-row').textContent,/직원 B/);
 host.querySelector('[data-mode=range]').click();await tick();assert.equal(calls.at(-1).name,'list_employee_payroll_range');
 host.querySelector('.payroll-from').value='2026-10-20';host.querySelector('.payroll-to').value='2026-10-10';host.querySelector('.payroll-to').dispatchEvent(new w.Event('change'));await tick();assert.match(host.querySelector('.payroll-message').textContent,/시작일/);
 host.querySelector('.payroll-to').value='2026-10-25';ids=['p3'];await control.refresh();assert.deepEqual(calls.at(-1).args.p_property_ids,['p3']);assert.equal(calls.at(-1).args.p_from_date,'2026-10-20');assert.equal(host.querySelectorAll('.payroll-employee-host [data-value]').length,1);assert.equal(host.querySelector('.payroll-employee-host [data-value]').dataset.value,'e3');
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
test('default order follows home branch and branch numbers, while name headers toggle 가나다 sorting',async()=>{
 const dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/attendance.html',runScripts:'outside-only'}),w=dom.window;
 const rows=[
  {employee_id:'third',property_id:'p3',property_name:'3번 지점',display_name:'나무',work_minutes:30,expected_pay:1000,pay_type:'hourly',hourly_rate:2000},
  {employee_id:'second',property_id:'p2',property_name:'2번 지점',display_name:'가람',work_minutes:60,expected_pay:2000,pay_type:'hourly',hourly_rate:2000},
  {employee_id:'home',property_id:'home',property_name:'본점',display_name:'다솜',work_minutes:90,expected_pay:3000,pay_type:'hourly',hourly_rate:2000}
 ];
 w.omgSupabase={rpc:async()=>({data:{ok:true,employees:rows}})};
 w.eval(fs.readFileSync('property-selector.js','utf8'));w.eval(fs.readFileSync('payroll.js','utf8'));
 w.OMSPayroll.init({accessToken:'token',getPropertyIds:()=>['p2','p3','home'],getPropertyNumber:id=>({p2:2,p3:3,home:10})[id],ownPropertyId:'home'});
 w.document.getElementById('openPayroll').click();await tick();const host=w.document.getElementById('payrollView'),names=()=>[...host.querySelectorAll('.payroll-person-name strong')].map(x=>x.textContent);
 assert.deepEqual(names(),['다솜','가람','나무']);assert.equal(host.querySelector('.payroll-sort'),null);
 const name=host.querySelector('.payroll-columns [data-sort=name]');assert.match(name.textContent,/이름.*↕/);name.click();assert.deepEqual(names(),['가람','나무','다솜']);assert.equal(name.getAttribute('aria-pressed'),'true');name.click();assert.deepEqual(names(),['다솜','나무','가람']);
 const work=host.querySelector('.payroll-columns [data-sort=work]');work.click();assert.equal(work.getAttribute('aria-pressed'),'true');assert.deepEqual(names(),['다솜','가람','나무']);
 host.querySelector('.payroll-columns [data-sort=pay]').click();assert.deepEqual(names(),['다솜','가람','나무']);w.close();
});
