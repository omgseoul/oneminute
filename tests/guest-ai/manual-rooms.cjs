const {setup,id}=require('../bot-briefing/setup.cjs'),assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{
 const db=await setup({monthly:true});
 for(const file of ['guest_ai_property_selection','guest_ai_manual_rooms','guest_ai_manual_test'])await db.exec(fs.readFileSync('supabase/setup/'+file+'.sql','utf8'));
 const p=id(1),p2=id(2),owner=id(3),token=id(4);
 await db.query("insert into properties(id,name,management_number)values($1,'Own',1),($2,'Other',2)",[p,p2]);
 await db.query("insert into owners(id,property_id,display_name)values($1,$2,'Owner')",[owner,p]);
 await db.query("insert into owner_sessions(owner_id,property_id,login_token_hash,token_expires_at)values($1,$2,omg_private.token_hash($3),'infinity')",[owner,p,token]);
 const q=async(sql,args=[])=>(await db.query(sql,args)).rows[0];
 const call=async(action,data={},t=token)=>(await q('select public.guest_ai_manual_test($1,$2,$3) v',[t,action,JSON.stringify({property_id:p,...data})])).v;
 const rows=[{number:'28',category:'시설',title:'난방',rooms:'101,102,103',answer:'중앙 난방'},{number:'29',category:'시설',title:'난방',rooms:'401',answer:'TV 왼쪽 보일러'},{title:'공통',answer:'공통 안내'},{title:'빈 답변',rooms:'401',answer:''},{title:'난방',rooms:'전체',answer:'기본 난방'}];
 const select=async room=>(await q('select omg_private.ai_manual_data($1,$2) v',[JSON.stringify(rows),room])).v;
 assert.deepEqual((await select('401호')).map(r=>r.id),['2','3']);assert.deepEqual((await select('101')).map(r=>r.id),['1','3']);assert.deepEqual((await select('1101')).map(r=>r.id),['3','5']);assert.deepEqual((await select(null)).map(r=>r.id),['3']);
 const saved=(await q("select public.guest_ai_owner($1,'save',$2) v",[token,JSON.stringify({property_id:p,enabled:false,mode:'always',prompt:'숙소 안내',data:rows})])).v;
 assert.equal(saved.settings.data[1].rooms,'401');assert.equal(saved.settings.data[1].category,'시설');assert.equal(saved.settings.data[1].number,'29');assert.equal(saved.settings.data[2].rooms,'전체');assert.equal(saved.settings.data.length,5);
 await db.exec("insert into omg_private.ai_provider(singleton,enabled,vault_id)values(true,true,gen_random_uuid()) on conflict(singleton)do update set enabled=true,vault_id=excluded.vault_id");
 await db.query('update omg_private.ai_wallets set enabled=true,monthly_limit_micro=1000000 where property_id=$1',[p]);
 const data={id:id(20),data:rows,prompt:'숙소 안내',question:'난방 조절?',room_number:'401'};
 await assert.rejects(()=>call('prepare',{...data,property_id:p2}),/권한/);await assert.rejects(()=>call('prepare',data,id(99)),/로그인/);
 await db.exec('set role anon');await assert.rejects(()=>call('finish',{id:id(20)}),/permission/);await db.exec('reset role');
 const job=await call('prepare',data);assert.equal(job.start,true);assert.deepEqual(job.job.data.map(r=>r.id),['2','3']);assert.equal((await call('prepare',data)).start,undefined);
 await assert.rejects(()=>call('prepare',{...data,id:id(21)}),/잠시|진행/);
 assert.equal((await call('attempt',{id:id(20)})).start,true);assert.equal((await call('attempt',{id:id(20)})).start,false);
 const result={reply:'TV 왼쪽',disposition:'answer',input_tokens:1000,output_tokens:200,cached_tokens:100};
 let finish=await call('finish',{id:id(20),result});assert.equal(finish.credits,.191);assert.equal(finish.status,'completed');assert.equal((await call('finish',{id:id(20),result})).credits,.191);assert.equal((await call('status',{id:id(20)})).usage.used,.191);
 assert.equal((await q('select count(*) n from guest_chat_messages')).n,0);assert.equal((await q('select count(*) n from property_messages')).n,0);assert.equal((await q('select count(*) n from omg_private.online_outbox')).n,0);
 await db.exec("update omg_private.ai_manual_tests set created_at=now()-interval '1 minute'");
 const pending=await call('prepare',{...data,id:id(21),room_number:''});assert.deepEqual(pending.job.data.map(r=>r.id),['3']);
 await call('attempt',{id:id(21)});await db.exec("update omg_private.ai_manual_tests set created_at=now()-interval '3 minutes' where status='pending'");
 await db.exec('select omg_private.ai_manual_test_recover()');
 const expired=await call('status',{id:id(21)});assert.equal(expired.status,'failed');assert(expired.credits>0);assert.equal(expired.usage.reserved,0);assert.equal((await call('finish',{id:id(21),result})).credits,expired.credits);
 // Both production claim paths carry the canonical room and use the same selector.
 for(const name of ['omg_private.ai_claim()','omg_private.online_internal(text,uuid,jsonb)']){const def=(await q('select pg_get_functiondef($1::regprocedure) d',[name])).d;assert(def.includes('ai_manual_data(s.data'));assert(def.includes("'room_number'"));assert(def.includes("'room_topics'"));}
 await db.close();console.log('PASS: five-column save, exact room selection/unknown/common overrides, isolated owner previews, metered idempotent billing, expiry recovery, production room context');
})().catch(e=>{console.error(e);process.exitCode=1});
