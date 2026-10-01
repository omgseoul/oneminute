// Disposable PostgreSQL tests; no live accounts or external services.
const {PGlite}=require('@electric-sql/pglite');
const {pgcrypto}=require('@electric-sql/pglite/contrib/pgcrypto');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..'),read=f=>fs.readFileSync(path.join(root,f),'utf8');
const db=new PGlite({extensions:{pgcrypto}});
let count=0;const check=(v,msg)=>{assert.ok(v,msg);count++;console.log('PASS '+msg);};
async function one(sql,args=[]){return(await db.query(sql,args)).rows[0];}
async function rpc(name,args){await db.exec('set role anon');try{return(await one(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).r;}finally{await db.exec('reset role');}}
(async()=>{
 await db.exec(`create role anon;create role authenticated;create role service_role;grant usage on schema public to anon,authenticated;
 create schema auth;create table auth.users(id uuid primary key,email text not null);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;`);
 // Hosted pg_cron/net/Vault dispatch scheduling is outside this disposable chat RPC suite.
 for(const f of fs.readdirSync(path.join(root,'migrations')).filter(f=>f.endsWith('.sql')&&!f.endsWith('_guest_email_worker_vault.sql')).sort())await db.exec(read('migrations/'+f));

 await db.exec(read('setup/002_register_employee_pins.example.sql').replace(/PIN_([1-4])/g,'731482'));
 await db.exec(read('setup/007_create_owner.example.sql').replace(/OWNER_LOGIN_ID/g,'boss.test').replace(/OWNER_PIN_6_TO_8/g,'517394'));
 const owner=await rpc('start_owner_session',['boss.test','517394']);
 const staff=(await db.query("select id,property_id from public.employees where active and role<>'owner' order by id")).rows;
 const worker=await rpc('start_work_session',[staff[0].id,'731482']);
 const call=async(action,data={},token=owner.access_token,guest=null)=>(await one('select public.guest_support_rpc($1,$2,$3,$4,$5) r',[action,JSON.stringify(data),token,guest,'a'.repeat(64)])).r;
 const rejected=async(fn,label)=>{await assert.rejects(fn);check(true,label);};
 let cfg=await call('settings');const slug=cfg.config.slug;
 check(!cfg.config.enabled,'new module is opt-in');
 const aid=require('node:crypto').randomUUID();
 await db.query("insert into public.guest_support_assets(id,property_id,uploader_key,object_path,mime,ready) values($1,$2,'test',$3,'image/jpeg',true)",[aid,cfg.config.property_id,'test/'+aid]);
 await call('save_settings',{enabled:true,chat_enabled:true,items:[{title:'휴지',asset_id:aid,icon:'13'}]});
 check((await call('portal',{slug},null)).items[0].icon==='13','chosen icon persists on public portal');
 await rejected(()=>call('save_settings',{items:[{title:'bad',asset_id:aid,icon:'51'}]}),'unknown icon rejected');
 await rejected(()=>call('save_settings',{items:Array.from({length:10},()=>({title:'too many',asset_id:aid}))}),'custom items limited to nine');
 await call('save_settings',{enabled:false,chat_enabled:false,items:[]});

 await rejected(()=>call('portal',{slug},null),'disabled portal cannot be opened');
 await call('save_settings',{enabled:true,chat_enabled:true,items:[]});
 const today=new Date().toISOString().slice(0,10),guest=require('node:crypto').randomUUID();
 const start={slug,name:'Test Guest',check_in:today,check_out:today,new_token:guest};
 await rejected(()=>call('start',{...start,entry_version:2,email:'bad',room_unknown:true},null),'invalid email rejected');
 await rejected(()=>call('start',{...start,entry_version:2,email:'test@example.com'},null),'room or explicit unknown required');
 const contact=await call('start',{...start,new_token:require('node:crypto').randomUUID(),entry_version:2,email:'Test@Example.com',room_unknown:true,room_number:'discarded'},null);
 const contactRow=await one('select email,room_unknown,room_number from public.guest_chat_rooms where id=$1',[contact.room_id]);
 check(contactRow.email==='test@example.com'&&contactRow.room_unknown&&contactRow.room_number===null,'contact information saved; unknown room clears room value');
 const room=await call('start',start,null);const id=room.room_id;
 check((await call('start',start,null)).room_id===id,'retried entry creates one room');
 await rejected(()=>call('messages',{room_id:id},null,require('node:crypto').randomUUID()),'invalid guest token rejected');
 await rejected(()=>call('settings',{},null,guest),'guest cannot access settings');
 await rejected(()=>call('save_settings',{enabled:false},worker.access_token),'worker cannot change owner settings');
 const cid=require('node:crypto').randomUUID();
 const sent=await call('send',{room_id:id,client_id:cid,body:'Help'},null,guest);
 check((await call('send',{room_id:id,client_id:cid,body:'Help'},null,guest)).message_id===sent.message_id,'send retry does not duplicate');
 const pendingView=await call('messages',{room_id:id});check(!!pendingView.room.unanswered_since,'guest question starts reply wait');await call('read',{room_id:id,last_seq:pendingView.messages.at(-1).seq});check((await call('messages',{room_id:id})).room.unanswered_since===pendingView.room.unanswered_since,'reading does not resolve reply wait');check((await call('rooms')).rooms.find(r=>r.id===id).unanswered_since===pendingView.room.unanswered_since,'room list and chat agree on reply wait');
 await call('send',{room_id:id,client_id:require('node:crypto').randomUUID(),body:'We can help'},worker.access_token);
 const view=await call('messages',{room_id:id},null,guest);check(view.room.unanswered_since===null,'staff reply clears pending status');
 check(view.messages[1].sender_name==='직원'&&view.messages[1].sender_key===null,'guest sees staff alias only');
 check(view.room.assigned_name==='직원'&&view.room.assigned_key===null,'assignment identity hidden from guest');
 const internal=await call('messages',{room_id:id});
 check(internal.messages[1].sender_key==='employee:'+staff[0].id,'internal record retains actual sender');

 check((await call('messages',{room_id:id})).room.unanswered_since===null,'system-free answered state stays resolved');
 console.log('PASS '+count+' guest reply metadata and authorization checks');await db.close();
})().catch(async e=>{console.error(e);await db.close();process.exitCode=1;});
