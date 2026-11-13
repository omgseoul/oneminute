const fs=require('node:fs'),assert=require('node:assert/strict');
module.exports=async({db,owner,internal,p1,p2,t2})=>{
 const hash=async name=>(await db.query('select md5(pg_get_functiondef($1::regprocedure)) h',[name])).rows[0].h;
 const protectedFns=['omg_private.online_internal(text,uuid,jsonb)','public.get_online_push_dispatch(uuid)'],before=await Promise.all(protectedFns.map(hash));
 const sql=fs.readFileSync('supabase/setup/beds24_message_alert_draft.sql','utf8');await db.exec(sql);await db.exec(sql);assert.deepEqual(await Promise.all(protectedFns.map(hash)),before,'notification creation and push routing functions remain unchanged');
 assert.equal((await owner('settings')).online_message_alert_draft,null);
 const config={staff:{enabled:true,mode:'strong',scopes:['checkin','staying']},owner:{enabled:false,mode:'weak',time_enabled:true,from:'21:00',to:'09:00',no_staff_only:true,scopes:['all','checkout']}};
 let result=await owner('save_message_alert_draft',{config});assert(result.pending);assert.equal(result.online_message_alert_draft.staff.mode,'strong');assert.deepEqual(result.online_message_alert_draft.owner.scopes,['all']);assert.equal((await owner('settings')).online_message_alert_draft.owner.from,'21:00');assert.equal((await owner('settings',{},t2)).online_message_alert_draft,null);
 await assert.rejects(()=>owner('save_message_alert_draft',{property_id:p2,config}),/권한/);
 const invalid=[{...config,staff:{...config.staff,mode:'emergency'}},{...config,staff:{...config.staff,enabled:'true'}},{...config,staff:{...config.staff,scopes:[]}},{...config,staff:{...config.staff,scopes:['other']}},{...config,owner:{...config.owner,from:'24:00'}},{...config,owner:{...config.owner,to:'21:00'}},{...config,owner:{...config.owner,no_staff_only:'yes'}}];
 for(const cfg of invalid)await assert.rejects(()=>owner('save_message_alert_draft',{config:cfg}),/설정|대상|시간|메시지/);
 await internal('messages',{notify:true,items:[{id:98001,bookingId:10,propertyId:100,source:'guest',message:'Synthetic online message for unchanged-delivery test',time:new Date().toISOString()}]});
 const mid=(await db.query('select notice_id from omg_private.online_messages where property_id=$1 and id=98001',[p1])).rows[0].notice_id;assert(mid);const recipients=(await db.query('select recipient_type from property_message_recipients where message_id=$1',[mid])).rows;assert(recipients.some(r=>r.recipient_type==='owner'),'existing owner receives despite pending draft disabling owner');assert(!recipients.some(r=>r.recipient_type==='staff'),'pending draft does not start staff notifications');const dispatch=(await db.query('select public.get_online_push_dispatch($1) v',[mid])).rows[0].v;assert(Object.values(dispatch.recipient_modes).every(v=>v==='normal'),'current fixed-normal guest notification strength remains unchanged');
 assert.equal((await db.query("select has_function_privilege('anon','omg_private.save_online_message_alert_draft(uuid,jsonb)','execute') v")).rows[0].v,false);
 console.log('Message alert draft DB: property-scoped persistence/validation, pending state, unchanged recipients, strength and routing, idempotence and denied anonymous access passed');
};
