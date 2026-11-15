module.exports=async({db,p1,p2,t1,t2,id})=>{
 const fs=require('fs'),assert=require('assert/strict');await db.exec(fs.readFileSync('supabase/setup/home_cleaning.sql','utf8'));
 const eid=id(99501),token=id(99502);await db.query("insert into employees(id,property_id,display_name) values($1,$2,'Cleaner')",[eid,p1]);await db.query("insert into work_sessions(employee_id,property_id,login_token_hash,token_expires_at,status)values($1,$2,omg_private.token_hash($3),'infinity','working')",[eid,p1,token]);
 const summary=async t=>(await db.query('select public.home_cleaning_summary($1) v',[t])).rows[0].v;
 const config=async(t,action='read',ids=null)=>(await db.query('select public.employee_cleaning_config($1,$2,$3,$4) v',[t,eid,action,ids])).rows[0].v;
 await db.exec('set role anon');assert.equal((await summary(token)).properties.length,1,'public client can call scoped helper without private schema usage');await assert.rejects(()=>summary(id(99999)),/로그인/);await db.exec('reset role');assert.equal((await summary(token)).properties.length,1);assert.equal((await summary(token)).properties[0].days.length,3);
 await assert.rejects(()=>config(token),/권한/);await assert.rejects(()=>config(t2),/권한/);await assert.rejects(()=>config(t1,'save',[p2]),/권한/);await assert.rejects(()=>summary(id(99999)),/로그인/);
 await db.query("insert into property_share_requests(requester_property_id,target_property_id,status,requested_permissions)values($1,$2,'approved',array['messages'])",[p1,p2]);
 await config(t1,'save',[p1,p2]);assert.equal((await summary(token)).properties.length,2);assert.equal((await config(t1)).properties.filter(p=>p.selected).length,2);
 const day=(await summary(token)).properties.find(p=>p.id===p1).days[0].day;
 const before=(await summary(token)).properties.find(p=>p.id===p1).days[0].count;
 await db.query("insert into omg_private.online_bookings(property_id,id,guest_name,arrival,departure,status,data)values($1,99501,'Synthetic',$2::date-1,$2,'confirmed','{\"roomId\":99,\"unitId\":1}'),($1,99502,'Synthetic',$2::date-1,$2,'confirmed','{\"roomId\":99,\"unitId\":1}')",[p1,day]);
 assert.equal((await summary(token)).properties.find(p=>p.id===p1).days[0].count,before+1,'same unit/date counted once');
 await db.query("update property_share_requests set status='revoked' where requester_property_id=$1 and target_property_id=$2",[p1,p2]);assert.equal((await summary(token)).properties.length,1,'revocation applies even to saved preferences');
 const v=(await db.query('select public.get_cleaning_arrivals($1,$2,$3) v',[token,p1,day])).rows[0].v;assert(v.ok);await assert.rejects(()=>db.query('select public.get_cleaning_arrivals($1,$2,$3)',[t2,p1,day]),/권한/);
 assert.equal((await db.query("select public.send_urgent_message($1,'retired') v",[token])).rows[0].v.ok,false);
 console.log('Home cleaning: persisted employee scopes, cross-tenant denial, revocation, three-day counts, unit dedupe and retired emergency action passed');
};
