const fs=require('fs'),assert=require('assert/strict');
module.exports=async({db,p1,p2,t1,t2,id})=>{
 // The online fixture does not include the complete QR gateway; retain its portal contract.
 await db.exec(`create or replace function public.guest_support_rpc(p_action text,p_data jsonb default '{}',p_token uuid default null,p_guest_token uuid default null,p_ip_hash text default '')returns jsonb language plpgsql as $$declare cfg public.guest_support_config%rowtype;begin select * into cfg from public.guest_support_config where slug=(p_data->>'slug')::uuid;return jsonb_build_object('chat_enabled',cfg.chat_enabled,'items',cfg.items);end$$;
 create or replace function omg_private.guest_limit(p_key text,p_limit int,p_seconds int)returns void language plpgsql as $$declare n int;begin insert into public.guest_support_limits(key,window_at,hits)values(p_key,now(),1)on conflict(key)do update set hits=guest_support_limits.hits+1 returning hits into n;if n>p_limit then raise exception '잠시 후 다시 시도해주세요.';end if;end$$;`);
 const sql=fs.readFileSync('supabase/setup/guest_web_checkin.sql','utf8');await db.exec(sql);await db.exec(sql);
 const overnight=fs.readFileSync('supabase/setup/web_checkin_overnight_choice.sql','utf8');await db.exec(overnight);await db.exec(overnight);
 const context=fs.readFileSync('supabase/setup/web_checkin_property_context.sql','utf8');await db.exec(context);await db.exec(context);
 const q=async(s,a=[])=>(await db.query(s,a)).rows,admin=async(t,a='read',d={})=>(await q('select public.web_checkin_admin($1,$2,$3) v',[t,a,d]))[0].v;
 for(const action of ['read','probe','save','record_probe'])await assert.rejects(()=>admin(t1,action,{property_id:p2,enabled:false}),/관리 권한/);
 assert.equal((await admin(t1,'read',{property_id:p1})).property_id,p1);
 await db.query("update property_share_requests set status='approved',requested_permissions=array['property_settings'] where requester_property_id=$1 and target_property_id=$2",[p1,p2]);
 await assert.rejects(()=>admin(t1,'read',{property_id:p2}),/관리 권한/);
 await db.query("update property_share_requests set requested_permissions=array['property_settings','messages'] where requester_property_id=$1 and target_property_id=$2",[p1,p2]);
 assert.equal((await admin(t1,'read',{property_id:p2})).property_id,p2,'authorized selected branch must not fall back to login property');
 await admin(t1,'save',{property_id:p2,release_time:'16:00'});assert.equal((await admin(t2)).release_time,'16:00');assert.equal((await admin(t1)).release_time,'15:00');
 await db.query("update property_share_requests set status='revoked' where requester_property_id=$1 and target_property_id=$2",[p1,p2]);
 await assert.rejects(()=>admin(t1,'probe',{property_id:p2}),/관리 권한/);

 let cfg=await admin(t1);assert.equal(cfg.enabled,false);assert.equal(cfg.source,'');
 assert.equal(cfg.end_time,'11:00');await assert.rejects(()=>admin(t1,'save',{end_time:'11:01'}),/오전 11시/);
 for(const [at,expected] of [['2026-11-16 14:59:59',false],['2026-11-16 15:00',true],['2026-11-17 00:00',true],['2026-11-17 11:00',true],['2026-11-17 11:00:01',false],['2026-11-18 00:00',false]])assert.equal((await q("select omg_private.web_checkin_in_window('2026-11-16','15:00','11:00',$1::timestamp) v",[at]))[0].v,expected);
 await assert.rejects(()=>admin(id(888888)),/관리자/);await assert.rejects(()=>admin(t1,'save',{enabled:true,source:'info:PIN'}),/연동 확인/);
 await admin(t1,'record_probe',{day:cfg.day,bookings:2,assigned:2,sources:[{source:'info:PIN',count:2}]});
 await admin(t1,'save',{enabled:true,source:'info:PIN',release_time:'00:00'});assert.equal((await admin(t2)).enabled,false,'other property is isolated');
 const slug=(await q('select slug from guest_support_config where property_id=$1',[p1]))[0].slug;
 const gate=async ip=>(await q('select public.web_checkin_gate($1,$2) v',[slug,ip]))[0].v;
 assert.equal((await gate('a'.repeat(64))).property_id,p1);assert(!(await gate('')).ok);
 for(let i=0;i<19;i++)await gate('a'.repeat(64));await assert.rejects(()=>gate('a'.repeat(64)),/잠시 후/);
 const release=async(src,day)=>(await q('select public.web_checkin_release($1,$2,$3) v',[p1,src,day]))[0].v;
 assert(await release('info:PIN',cfg.day));assert.equal(await release('info:OTHER',cfg.day),false);assert.equal(await release('info:PIN','2000-01-01'),false);
 const portal=(await q("select public.guest_support_rpc('portal',$1) v",[{slug}]))[0].v;assert.equal(portal.web_checkin_enabled,true);assert(!JSON.stringify(portal).includes('info:PIN'));
 await admin(t1,'save',{enabled:false,source:'info:PIN'});assert(!(await gate('b'.repeat(64))).ok);assert.equal(await release('info:PIN',cfg.day),false);
 for(const role of ['anon','authenticated']){assert.equal((await q("select has_function_privilege($1,'public.web_checkin_gate(uuid,text)','execute') v",[role]))[0].v,false);assert.equal((await q("select has_function_privilege($1,'public.web_checkin_admin(uuid,text,jsonb)','execute') v",[role]))[0].v,false);assert.equal((await q("select has_table_privilege($1,'omg_private.web_checkin_settings','select') v",[role]))[0].v,false);}
 const options=Array.from({length:15},(_,i)=>({id:id(90000+i),label:i?'Invented '+i:'Fixture Guest'})),fingerprint='a'.repeat(64),token=id(999000);
 const identity=async(booking,choice=null,overrides={})=>{const a={property:p1,booking,token,fingerprint,strong:false,can:true,options,correct:options[0].id,choice,...overrides};return(await q('select public.web_checkin_identity($1,$2,$3,$4,$5,$6,$7,$8,$9) v',Object.values(a)))[0].v;};
 let challenge=await identity(1);assert.equal(challenge.options.length,15);assert.equal(challenge.attempts_remaining,2);assert.equal(challenge.correct_id,undefined);
 assert.deepEqual((await identity(1,null,{options:options.map(x=>({...x,label:'Changed '+x.label}))})).options,options,'cannot rotate decoys and intersect true names');
 assert.equal((await identity(1,options[1].id)).attempts_remaining,1);assert.equal((await identity(1,options[1].id)).attempts_remaining,1,'network replay is idempotent');
 assert.equal((await identity(1,null,{strong:true})).verified,undefined,'cannot bypass pending challenge by copying displayed name');
 assert.equal((await identity(1,options[2].id)).ok,false);assert.equal((await identity(1,options[0].id)).ok,false);assert.equal((await identity(1,null,{strong:true,token:id(999001)})).ok,false,'new device cannot reset attempts');
 assert.equal((await identity(2)).attempts_remaining,2);assert.equal((await identity(2,options[1].id)).attempts_remaining,1);assert.equal((await identity(2,options[0].id)).verified,true);
 assert.equal((await identity(2,options[0].id,{fingerprint:'b'.repeat(64)})).ok,false);await identity(3);await q("update omg_private.web_checkin_name_challenges set expires_at=now()-interval '1 minute' where booking_id=3");assert.equal((await identity(3,options[0].id)).ok,false);
 for(const role of ['anon','authenticated']){assert.equal((await q("select has_function_privilege($1,'public.web_checkin_identity(uuid,bigint,uuid,text,boolean,boolean,jsonb,uuid,uuid)','execute') v",[role]))[0].v,false);assert.equal((await q("select has_table_privilege($1,'omg_private.web_checkin_name_challenges','select') v",[role]))[0].v,false);}
 await require('./web-checkin-flow.cjs')({db,p1,p2,id});
 console.log('Web check-in database: default off, tested source required, property isolation, IP attempts, day/release/source recheck, portal secrecy and service-only RPC passed');
};
