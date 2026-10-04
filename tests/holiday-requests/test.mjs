import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
const root=new URL('../../',import.meta.url).pathname;
await db.exec(fs.readFileSync(new URL('./schema.sql',import.meta.url),'utf8'));
await db.exec(fs.readFileSync(root+'/supabase/migrations/20261004025433_holiday_requests_approval_calendar.sql','utf8'));
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
for(let p=1;p<=2;p++){
 await db.query('insert into properties(id,name) values($1,$2)',[id(p),'Test '+p]);
 await db.query('insert into owners(id,property_id,display_name) values($1,$2,$3)',[id(10+p),id(p),'Owner '+p]);
 await db.query("insert into owner_sessions(owner_id,property_id,business_id,login_token_hash,token_expires_at) values($1,$2,$3,md5($4),now()+interval '1 day')",[id(10+p),id(p),id(90),id(100+p)]);
}
for(let e=1;e<=3;e++){
 const p=e===3?2:1;
 await db.query('insert into employees(id,property_id,display_name) values($1,$2,$3)',[id(20+e),id(p),'Staff '+e]);
 await db.query("insert into work_sessions(employee_id,property_id,business_id,login_token_hash,token_expires_at) values($1,$2,$3,md5($4),now()+interval '1 day')",[id(20+e),id(p),id(90),id(200+e)]);
}
let checks=0;
const ok=(v,label)=>{assert(v,label);checks++;console.log('PASS '+label)};
const call=async(token,action,data={})=>(await db.query('select holiday_request_action($1,$2,$3) result',[id(token),action,JSON.stringify(data)])).rows[0].result;
const list=async(token)=>(await db.query('select list_property_messages($1) result',[id(token)])).rows[0].result;
const cal=async(token,action='list',data={range_start:'2026-10-01',range_end:'2026-11-01'})=>(await db.query('select calendar_event_action($1,$2,$3) result',[id(token),action,JSON.stringify(data)])).rows[0].result;
const base={id:id(300),holiday_date:'2026-10-15',reason:'Personal appointment',target_employee_ids:[id(21),id(22)],notice_seen:true,acknowledged:true};
ok(!(await call(999,'context')).ok,'invalid session denied');
ok((await call(201,'context')).employees.length===2,'context limited to own property');
ok(!(await call(201,'settings_save',{})).ok,'staff cannot edit settings');
ok(!(await call(201,'submit',{...base,acknowledged:false})).ok,'acknowledgement required');
ok(!(await call(201,'submit',{...base,target_employee_ids:[id(23)]})).ok,'cross property target denied');
const sent=await call(201,'submit',base);ok(sent.ok,'multiple staff request submitted');
ok((await call(201,'submit',base)).id===sent.id,'submission retry idempotent');
ok(!(await call(201,'submit',{...base,id:id(301)})).ok,'duplicate date target blocked');
ok(!(await call(201,'approve',{id:sent.id})).ok,'staff approval denied');
ok(!(await call(102,'approve',{id:sent.id})).ok,'unrelated owner approval denied');
const pending=await cal(202);ok(pending.events.length===1&&pending.events[0].title==='휴일 (미결재)'&&!pending.events[0].can_edit,'target calendar pending and read only');
ok((await cal(203)).events.length===0,'other property calendar private');
ok(!(await cal(201,'delete',{id:pending.events[0].id})).ok,'cannot delete managed holiday');
ok((await list(101)).messages.some(m=>m.message_type==='holiday_approval'&&m.approval_status==='pending'),'owner approval item');
ok((await list(202)).messages.some(m=>m.message_type==='holiday_notice'&&m.message.startsWith('미결재 - 휴일신청')),'target pending notification');
ok((await list(203)).messages.length===0,'other property messages private');
const approved=await call(101,'approve',{id:sent.id});ok(approved.ok,'owner approved');
const approvedCal=await cal(202);ok(approvedCal.events.length===1&&approvedCal.events[0].id===pending.events[0].id&&approvedCal.events[0].title==='휴일 (결재완료)','same calendar event updated');
ok((await list(202)).messages.some(m=>m.message_type==='holiday_notice'&&m.approval_status==='approved'&&m.message.startsWith('결재완료 - 휴일신청')&&!m.read_at),'same notification updated unread');
ok((await call(101,'approve',{id:sent.id})).ok,'approval retry safe');
ok(!(await call(101,'reject',{id:sent.id})).ok,'decided request immutable');
const push=(await db.query('select get_message_push_dispatch($1,$2) result',[id(101),approved.message_id])).rows[0].result;
ok(push.ok&&push.recipient_employee_ids.length===2,'approval notification dispatch to targets');
const s=await call(101,'settings_save',{notice_enabled:true,notice_text:'New notice',acknowledgement_required:true,acknowledgement_label:'Read'});ok(s.ok,'owner saves notice');
ok(!(await call(201,'submit',{...base,id:id(302),holiday_date:'2026-10-16'})).ok,'stale notice version denied');
const r=await call(201,'submit',{...base,id:id(302),holiday_date:'2026-10-16',notice_version:s.settings.updated_at});ok(r.ok,'current notice accepted');
ok((await call(101,'reject',{id:r.id})).ok,'reject flow');
ok(!(await cal(201)).events.some(e=>e.holiday_request_id===r.id),'rejection removes pending event');
await db.exec('set role anon');
try{await db.query('select * from holiday_requests');throw Error('access allowed')}catch(e){ok(e.message.includes('permission denied'),'direct table access denied')}
await db.exec('reset role');
console.log(`${checks} assertions passed`);
await db.close();
