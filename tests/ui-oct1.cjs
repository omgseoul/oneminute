const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const status=require('../guest-reply-status.js'),summarize=require('../attendance-summary.js');
const now=Date.parse('2026-10-01T02:00:00Z');
assert.equal(status({},now),'');assert.equal(status({unanswered_since:'invalid'},now),'');
assert.equal(status({unanswered_since:'2026-10-01T01:50:00Z'},now),'미응답');
assert.equal(status({unanswered_since:'2026-10-01T01:48:00Z'},now),'미응답 지연 12분');
const rows=[{property_id:'p',employee_id:'a',work_date:'2026-09-30',clock_in_at:'2026-09-30T01:00Z',attendance_labels:['정상']},{property_id:'p',employee_id:'a',work_date:'2026-09-30',clock_in_at:'2026-09-30T03:00Z',attendance_labels:['지각']},{property_id:'p',employee_id:'a',work_date:'2026-10-01',clock_in_at:'2026-10-01T01:15Z',attendance_labels:['지각']},{property_id:'q',employee_id:'a',work_date:'2026-10-01',clock_in_at:'2026-10-01T01:20Z',attendance_labels:['지각']}];
assert.equal(summarize.lateItems(rows).length,2);assert.equal(summarize.lateItems(rows).length,summarize(rows).lateDays);
for(const file of fs.readdirSync('.').filter(f=>f.endsWith('.html'))){const html=fs.readFileSync(file,'utf8');for(const m of html.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/g))if(!/\bsrc=/.test(m[1]||''))new vm.Script(m[2],{filename:file});}
for(const file of ['photo-codec.js','attendance-export.js','guest-reply-status.js','guest-chat.js','message-hub.js','staff-chat-client.js'])new vm.Script(fs.readFileSync(file,'utf8'),{filename:file});
const {workbook}=require('../attendance-export.js');fs.writeFileSync('/tmp/omg-attendance-test.xlsx',workbook([['날짜','근무자','지점','근무시간(분)','근무시간','출근','퇴근','상태','근태','수정 상태'],['2026-10-01','=HYPERLINK("bad")','One & <Minute>',135,'2시간 15분','09:15','11:30','완료','지각','']]));
console.log('PASS: delay threshold, replied/no-message states, unique lateness drill-down, inline syntax, XLSX generation');
