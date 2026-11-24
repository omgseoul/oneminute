const assert=require('node:assert/strict'),{randomUUID}=require('crypto');
module.exports=async({db,rpc,token,session:s,employee:e})=>{
 const one=async(q,a=[])=>(await db.query(q,a)).rows[0];
 await db.query('delete from work_reports where work_session_id=$1',[s.id]);
 await db.query("update work_sessions set checkin_report_at=null,checkout_report_at=null,clock_out_at=null,unconfirmed_ended_at=null,next_confirmation_at=null,status='working',nfc_entry_at=null,nfc_tag_uid=null,clock_in_at=clock_timestamp()-interval '2 hours' where id=$1",[s.id]);
 await db.query("update properties set clock_in_basis='nfc',attendance_nfc_tags=array['04112233445566'] where id=$1",[e.property_id]);
 assert.equal((await rpc('attendance_nfc_entry',[token,'DEADBEEF'])).code,'wrong_tag');
 assert.equal((await rpc('save_work_report',[token,'clock_in',{}])).code,'nfc_required','no NFC cannot complete attendance');
 const first=await rpc('attendance_nfc_entry',[token,'04112233445566']);assert.equal(first.nfc_entries.length,1);
 const duplicate=await rpc('attendance_nfc_entry',[token,'04112233445566']);assert.equal(duplicate.nfc_entries.length,1,'held-tag callback debounced');
 await db.query("update omg_private.attendance_nfc_entries set recorded_at=clock_timestamp()-interval '10 minutes' where work_session_id=$1",[s.id]);
 const second=await rpc('attendance_nfc_entry',[token,'04112233445566']);assert.equal(second.nfc_entries.length,2,'second tag remains available');
 const pending=await rpc('save_work_report',[token,'clock_in',{}]);assert.equal(pending.code,'nfc_selection_required');
 assert.equal((await one('select checkin_report_at from work_sessions where id=$1',[s.id])).checkin_report_at,null,'no check-in until a time is chosen');
 assert.equal((await one('select count(*) n from work_reports where work_session_id=$1',[s.id])).n,0);
 assert.equal((await rpc('attendance_nfc_select',[token,randomUUID()])).code,'invalid_nfc_entry');

 const other=await one('select id from work_sessions where id<>$1 limit 1',[s.id]);
 if(other){const foreign=await one("insert into omg_private.attendance_nfc_entries(work_session_id,tag_uid)values($1,'04112233445566') returning id",[other.id]);assert.equal((await rpc('attendance_nfc_select',[token,foreign.id])).code,'invalid_nfc_entry');}
 const choice=second.nfc_entries[1];
 const selected=await rpc('attendance_nfc_select',[token,choice.id]);assert(selected.ok);assert.equal(selected.selected_entry_id,choice.id);assert.equal(new Date(selected.entry_at).getTime(),new Date(choice.recorded_at).getTime());assert.equal((await one('select checkin_report_at from work_sessions where id=$1',[s.id])).checkin_report_at,null,'menu selection does not submit report');
 const saved=await rpc('save_work_report',[token,'clock_in',{attendance_nfc_entry_id:second.nfc_entries[0].id,attendance_clock_in_at:'2000-01-01',text:'출근시각: 위조'}]);assert(saved.ok);assert.equal(saved.payload.attendance_nfc_entry_id,choice.id);assert.equal(new Date(saved.payload.attendance_clock_in_at).getTime(),new Date(choice.recorded_at).getTime());
 const session=await one('select clock_in_at,nfc_entry_at,work_date from work_sessions where id=$1',[s.id]);assert.equal(new Date(session.clock_in_at).getTime(),new Date(choice.recorded_at).getTime());assert.equal(new Date(session.nfc_entry_at).getTime(),new Date(choice.recorded_at).getTime());
 const retry=await rpc('save_work_report',[token,'clock_in',{attendance_nfc_entry_id:second.nfc_entries[0].id}]);assert(retry.already_saved);assert.equal(retry.payload.attendance_nfc_entry_id,choice.id,'retry cannot change confirmed time');
 assert.equal((await rpc('attendance_nfc_select',[token,second.nfc_entries[0].id])).ok,false,'confirmed selection cannot change');
 assert.equal((await rpc('attendance_nfc_entry',[token,'04112233445566'])).ok,false,'confirmed shifts cannot add tags');
 assert.equal((await rpc('attendance_nfc_entry',[randomUUID(),null])).code,'invalid_session');
 assert(!(await one("select has_table_privilege('anon','omg_private.attendance_nfc_entries','select') allowed")).allowed);
 console.log('PASS NFC choices: server times, multi-tag, duplicate debounce, choice required, no premature report, invalid/foreign selection, exact selected time, retry and private storage');
};
