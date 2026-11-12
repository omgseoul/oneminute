const {PGlite}=require('@electric-sql/pglite'),fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const db=new PGlite();await db.exec(fs.readFileSync('tests/holiday-requests/schema.sql','utf8'));
 await db.exec('alter table property_message_recipients add unique(message_id,recipient_key)');
 const original=fs.readFileSync('supabase/migrations/026_shared_messaging_and_approvals.sql','utf8');
 await db.exec(original.slice(original.indexOf('create or replace function public.approve_property_share('),original.indexOf('create or replace function public.list_working_employees(')));
 await db.exec(fs.readFileSync('supabase/setup/property_share_rejection.sql','utf8'));
 const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 for(let n=1;n<=3;n++){
  await db.query('insert into properties(id,name) values($1,$2)',[id(n),'Fixture '+n]);
  await db.query('insert into owners(id,property_id,display_name) values($1,$2,$3)',[id(10+n),id(n),'Fixture owner']);
  await db.query("insert into owner_sessions(owner_id,property_id,login_token_hash,token_expires_at) values($1,$2,md5($3),now()+interval '1 day')",[id(10+n),id(n),id(100+n)]);
 }
 for(let n=1;n<=2;n++)await db.query("insert into property_share_requests(id,requester_property_id,target_property_id,requester_owner_id,requested_permissions) values($1,$2,$3,$4,'{messages,property_settings}')",[id(200+n),id(1),id(2),id(11)]);
 await db.query("insert into property_messages(id,property_id,property_share_request_id,message_type) values($1,$2,$3,'property_share_approval')",[id(301),id(1),id(201)]);
 await db.query("insert into property_message_recipients(message_id,recipient_key,recipient_type,owner_id) values($1,'owner:fixture','owner',$2)",[id(301),id(12)]);
 const action=async(fn,token,request)=>(await db.query(`select public.${fn}($1,$2) result`,[id(token),id(request)])).rows[0].result;
 assert.equal((await action('reject_property_share',999,201)).code,'owner_required');
 assert.equal((await action('reject_property_share',101,201)).code,'not_found','requester cannot reject');
 assert.equal((await action('reject_property_share',103,201)).code,'not_found','unrelated owner cannot reject');
 await db.query("update owner_sessions set token_expires_at=now()-interval '1 minute' where owner_id=$1",[id(12)]);
 assert.equal((await action('reject_property_share',102,201)).code,'owner_required');
 await db.query("update owner_sessions set token_expires_at=now()+interval '1 day' where owner_id=$1",[id(12)]);
 await db.query('update owners set active=false where id=$1',[id(12)]);
 assert.equal((await action('reject_property_share',102,201)).code,'owner_required');
 await db.query('update owners set active=true where id=$1',[id(12)]);
 assert.equal((await action('reject_property_share',102,201)).status,'rejected');
 assert.equal((await action('reject_property_share',102,201)).already_rejected,true);
 assert.equal((await action('approve_property_share',102,201)).code,'not_pending','cannot approve rejected request');
 assert.equal((await action('approve_property_share',102,202)).status,'approved');
 assert.equal((await action('reject_property_share',102,202)).code,'not_pending','cannot reject approved access');
 const row=(await db.query('select * from property_share_requests where id=$1',[id(201)])).rows[0];
 assert.equal(row.status,'rejected');assert.equal(row.approved_at,null);assert.equal(row.approved_by,null);
 assert((await db.query('select read_at from property_message_recipients')).rows[0].read_at);
 assert.equal((await db.query("select has_function_privilege('anon','public.reject_property_share(uuid,uuid)','execute') allowed")).rows[0].allowed,true);
 await db.close();console.log('Sharing rejection: target-owner authorization, invalid/expired/inactive sessions, first decision wins, idempotency and no permission grant passed.');
})().catch(e=>{console.error(e);process.exit(1)});
