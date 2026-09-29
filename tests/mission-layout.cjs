const {JSDOM}=require('jsdom');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const html=fs.readFileSync('mission.html','utf8');
const dom=new JSDOM(html,{runScripts:'outside-only'}),w=dom.window;
const script=[...w.document.scripts].findLast(s=>!s.src).textContent.split('(async()=>{session=')[0];
w.setInterval=()=>0;w.eval(script+"\nwindow.testEval=(code)=>eval(code);");
const run=x=>w.testEval(x);
run('session={employeeId:"a",employeeName:"니완"};config={property:{name:"Test"}};');
for(const [days,key] of [[-1,'overdue'],[0,'today'],[1,'this_week'],[7,'this_week'],[8,'anytime'],[28,'anytime'],[35,'anytime']]){
 assert.equal(run(`sectionKey({due_at:dateAfterDays(${days})+'T23:59:59',target_count:1,completed_count:0})`),key);
}
run(`missions=[{id:'later',due_at:dateAfterDays(35),created_at:'2026-01-01',title:'later'},{id:'new',due_at:dateAfterDays(10),created_at:'2026-02-01',title:'new'},{id:'old',due_at:dateAfterDays(10),created_at:'2026-01-01',title:'old'}];expanded.anytime=true;render();`);
assert.deepEqual([...w.document.querySelectorAll('#section-anytime h3')].map(n=>n.textContent),['old','new','later']);
const active=run(`missionCard({title:'업무',description:'내용',priority:'normal',target_names:['니완'],target_count:5,completed_count:1,due_at:dateAfterDays(10)})`);
assert.equal(active.children.length,2);assert.equal(active.querySelector('.mission-progress').textContent,'1/5');assert.equal(active.querySelector('.mission-status'),null);
const done=run(`missionCard({title:'끝난 업무',priority:'normal',target_names:['다른담당자'],target_count:1,completed_count:1,completions:[{employee_id:'a',employee_name:'실제완료자'}]})`);
assert.equal(done.children.length,1);assert.equal(done.querySelector('.target').textContent,'실제완료자');assert.equal(done.querySelector('.mission-progress'),null);
done.click();assert.equal(w.document.getElementById('detailOverlay').hidden,false);
const timing=w.document.getElementById('timing'),due=w.document.getElementById('dueAt');
timing.value='anytime';timing.dispatchEvent(new w.Event('change'));assert.equal(due.value,run('dateAfterDays(28)'));
due.value=run('dateAfterDays(35)');due.dispatchEvent(new w.Event('change'));assert.equal(timing.value,'anytime');assert.equal(due.value,run('dateAfterDays(35)'));
due.value=run('dateAfterDays(3)');due.dispatchEvent(new w.Event('change'));assert.equal(timing.value,'this_week');
run(`workerFilterControl={value:()=>"a"}`);assert.equal(run(`sectionKey({target_count:5,completed_count:1,completion_employee_ids:['a']})`),'completed');
console.log('PASS: date groups, deadline ordering, compact cards, completion details, editable 28-day default, employee completion');
