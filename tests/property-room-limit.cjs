const {PGlite}=require('@electric-sql/pglite'),{JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
(async()=>{const db=new PGlite();try{
 await db.exec("create role anon;create role authenticated;create schema omg_private;create table omg_private.service_plans(code text primary key,room_limit integer);insert into omg_private.service_plans values('basic',10),('large',20);create table public.properties(id int primary key,rooms jsonb default '[]',billing_exempt boolean default false,service_plan text default 'basic');");
 const prior=fs.readFileSync('supabase/migrations/20261106015218_employee_login_and_plan_limits.sql','utf8');await db.exec(prior.slice(prior.indexOf('CREATE OR REPLACE FUNCTION omg_private.guard_room_limit()'),prior.indexOf('CREATE OR REPLACE FUNCTION public.start_account_work_session_by_login')));
 const rooms=n=>JSON.stringify(Array.from({length:n},(_,i)=>String(101+i))),update=(id,n)=>db.query('update properties set rooms=$1 where id=$2',[rooms(n),id]);
 await db.exec("insert into properties(id,billing_exempt) values(1,true),(2,false),(3,null);insert into properties(id,service_plan) values(4,'large');");
 await assert.rejects(()=>update(1,12),/객실 수 한도\(10개\)/,'reproduce exempt SeoulNest import save failure');
 await db.exec(fs.readFileSync('supabase/setup/exempt_property_room_limit.sql','utf8'));
 await update(1,12);assert.equal((await db.query('select jsonb_array_length(rooms) n from properties where id=1')).rows[0].n,12);
 await update(2,10);await assert.rejects(()=>update(2,12),/객실 수 한도\(10개\)/);await assert.rejects(()=>update(3,12),/객실 수 한도\(10개\)/);await update(4,20);await assert.rejects(()=>update(4,21),/객실 수 한도\(20개\)/);
 await db.query('insert into properties(id,rooms,billing_exempt) values(5,$1,true)',[rooms(12)]);await db.exec('update properties set billing_exempt=false where id=5');await update(5,11);await assert.rejects(()=>update(5,12),/객실 수 한도/);
 assert.equal((await db.query("select has_function_privilege('anon','omg_private.guard_room_limit()','EXECUTE') v")).rows[0].v,false);
 const w=new JSDOM('',{runScripts:'outside-only'}).window;w.eval(fs.readFileSync('work-config.js','utf8'));let error={code:'23514',message:'요금제의 객실 수 한도(10개)를 초과했습니다.'};w.omgSupabase={rpc:async()=>({data:null,error})};
 const save=()=>w.omgWorkConfig.save('token','Seoulnest','lodging',[{name:'Double Room',rooms:['401']}],[],{});
 await assert.rejects(save,/요금제의 객실 수 한도\(10개\)/);error={code:'23514',message:'internal constraint details containing private data'};await assert.rejects(save,e=>e.message==='설정을 저장하지 못했습니다. 잠시 후 다시 시도해주세요.');error={message:'Failed to fetch'};await assert.rejects(()=>w.omgWorkConfig.load('token'),/설정을 불러오지 못/);w.close();
 console.log('Room quota: reproduced exempt 12-room failure; exempt saves/inserts succeed; normal/null plans remain capped; reductions, RPC safety and truthful save errors pass');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
