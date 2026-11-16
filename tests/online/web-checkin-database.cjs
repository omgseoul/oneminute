const fs=require('fs'),assert=require('assert/strict');
module.exports=async({db,p1,p2,t1,t2,id})=>{
 // The online fixture does not include the complete QR gateway; retain its portal contract.
 await db.exec(`create or replace function public.guest_support_rpc(p_action text,p_data jsonb default '{}',p_token uuid default null,p_guest_token uuid default null,p_ip_hash text default '')returns jsonb language plpgsql as $$declare cfg public.guest_support_config%rowtype;begin select * into cfg from public.guest_support_config where slug=(p_data->>'slug')::uuid;return jsonb_build_object('chat_enabled',cfg.chat_enabled,'items',cfg.items);end$$;
 create or replace function omg_private.guest_limit(p_key text,p_limit int,p_seconds int)returns void language plpgsql as $$declare n int;begin insert into public.guest_support_limits(key,window_at,hits)values(p_key,now(),1)on conflict(key)do update set hits=guest_support_limits.hits+1 returning hits into n;if n>p_limit then raise exception '잠시 후 다시 시도해주세요.';end if;end$$;`);
 const sql=fs.readFileSync('supabase/setup/guest_web_checkin.sql','utf8');await db.exec(sql);await db.exec(sql);
 const q=async(s,a=[])=>(await db.query(s,a)).rows,admin=async(t,a='read',d={})=>(await q('select public.web_checkin_admin($1,$2,$3) v',[t,a,d]))[0].v;
 let cfg=await admin(t1);assert.equal(cfg.enabled,false);assert.equal(cfg.source,'');
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
 console.log('Web check-in database: default off, tested source required, property isolation, IP attempts, day/release/source recheck, portal secrecy and service-only RPC passed');
};
