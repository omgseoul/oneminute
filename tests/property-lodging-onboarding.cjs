const {PGlite}=require('@electric-sql/pglite'),fs=require('fs'),assert=require('node:assert/strict');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
(async()=>{const db=new PGlite();try{
 await db.exec(`create schema omg_private;
 create table properties(id uuid primary key,name text,business_type text,custom_report_fields jsonb default '[]',rooms jsonb not null default '[]',room_types jsonb not null default '[]');
 create table owners(id uuid primary key,active boolean default true);
 create table owner_sessions(owner_id uuid,property_id uuid,login_token_hash text,token_expires_at timestamptz);
 create table employees(id uuid,property_id uuid,active boolean,report_config jsonb);
 create function omg_private.token_hash(uuid) returns text language sql as $$select $1::text$$;
 create function omg_private.custom_report_fields_are_valid(jsonb) returns boolean language sql as $$select jsonb_typeof($1)='array'$$;
 create function omg_private.report_config_is_valid(jsonb) returns boolean language sql as $$select true$$;
 create function omg_private.can_manage_shared_property(uuid,uuid,text) returns boolean language sql as $$select $1='${id(10)}'::uuid and $2='${id(2)}'::uuid$$;
 create function public.get_work_app_config(uuid) returns jsonb language sql as $$select jsonb_build_object('ok',true,'property',to_jsonb(p)) from public.properties p join public.owner_sessions s on s.property_id=p.id where s.login_token_hash=$1::text$$;
 create function public.shared_get_work_app_config(uuid,uuid,text) returns jsonb language sql as $$select jsonb_build_object('ok',true,'property',to_jsonb(p)) from public.properties p where id=$2$$;
 insert into properties(id,name) values('${id(1)}','Own'),('${id(2)}','Shared');
 insert into owners(id) values('${id(1)}');insert into owner_sessions values('${id(1)}','${id(1)}','${id(10)}',now()+interval '1 hour');`);
 const source=fs.readFileSync('supabase/migrations/20261012045008_optional_room_numbers.sql','utf8');
 for(const match of source.matchAll(/CREATE OR REPLACE FUNCTION[\s\S]*?\$function\$;/g))if(match[0].includes('FUNCTION omg_private.room_types_are_valid')||match[0].includes('p_business_type text'))await db.exec(match[0]);
 const save=async(groups,shared=false,token=id(10),property=id(2))=>{const args=shared?[token,property,'Name','[]','{}',JSON.stringify(groups),'lodging','[]']:[token,'Name','[]','{}',JSON.stringify(groups),'lodging','[]'];return (await db.query(`select public.${shared?'shared_':''}save_property_settings(${args.map((_,i)=>'$'+(i+1)).join(',')}) v`,args)).rows[0].v;};
 assert.equal((await save([])).code,'invalid_room_types');assert.equal((await save([],true)).code,'invalid_room_types');
 await db.exec(fs.readFileSync('supabase/setup/property_lodging_onboarding.sql','utf8'));
 for(const shared of [false,true]){
  const v=await save([],shared);assert.equal(v.ok,true);assert.equal(v.property.business_type,'lodging');assert.deepEqual(v.property.rooms,[]);assert.deepEqual(v.property.room_types,[]);
  const rooms=[{name:'Double',rooms:['201','202']}];assert.deepEqual((await save(rooms,shared)).property.rooms,['201','202']);assert.deepEqual((await save(rooms,shared)).property.room_types,rooms);
  for(const groups of [null,[{name:'',rooms:['201']}],[{name:'Double',rooms:['201','201']}]])assert.equal((await save(groups,shared)).ok,false);
  assert.equal((await save([],shared,id(999))).code,'owner_required');
 }
 assert.equal((await save([],true,id(10),id(999))).ok,false);
 console.log('Lodging onboarding: reproduced empty-room failure; own/shared save empty, add rooms later, invalid rows and authorization pass');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
