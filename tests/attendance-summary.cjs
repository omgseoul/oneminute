const assert=require('node:assert/strict');
const summarize=require('../attendance-summary.js');
const fs=require('node:fs'),vm=require('node:vm');
const row=(date,time,minutes,labels=['정상'],employee='a')=>({employee_id:employee,work_date:date,clock_in_at:`${date}T${time}:00+09:00`,duration_minutes:minutes,attendance_labels:labels});
assert.deepEqual(summarize([]),{workDays:0,lateDays:0,averageMinutes:0});
assert.deepEqual(summarize([row('2026-09-29','11:00',120),row('2026-09-29','15:00',180,['지각']),row('2026-09-30','11:11',null,['지각'])]),{workDays:1,lateDays:1,averageMinutes:300});
assert.deepEqual(summarize([row('2026-09-29','11:11',120,['지각']),row('2026-09-29','13:00',180,['지각']),row('2026-09-29','11:00',240,['정상'],'b')]),{workDays:2,lateDays:1,averageMinutes:270});
for(const file of ['attendance.html','staff-management.html','messages.html']){
 const html=fs.readFileSync(file,'utf8');for(const m of html.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/g))if(!/\bsrc=/.test(m[1]||''))new vm.Script(m[2],{filename:file});
}
const html=fs.readFileSync('staff-management.html','utf8');
const helper=html.slice(html.indexOf('const warningHelpToggle'),html.indexOf('const form='));
const help={hidden:true},btn={attrs:{},setAttribute(k,v){this.attrs[k]=v},focus(){}},events={};
vm.runInNewContext(helper,{document:{getElementById:id=>id==='warningHelpToggle'?btn:help,addEventListener:(name,fn)=>events[name]=fn}});
btn.onclick();assert.equal(help.hidden,false);assert.equal(btn.attrs['aria-expanded'],'true');events.keydown({key:'Escape'});assert.equal(help.hidden,true);
const sql=fs.readFileSync('supabase/migrations/029_attendance_classification_and_notice_recipients.sql','utf8');
assert.ok(sql.includes('p_clock_in_at>v_expected_in+make_interval(mins=>coalesce(p_lateness_minutes,0))'));
console.log('PASS: unique completed days, average daily hours, first-arrival lateness, pending/missing shifts, script syntax, help toggle/Escape, configured lateness threshold wiring');
