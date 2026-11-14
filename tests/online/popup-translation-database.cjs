const fs=require('node:fs'),assert=require('node:assert/strict');
module.exports=async({db,p1,id,owner,internal})=>{
 const sql=fs.readFileSync('supabase/setup/beds24_popup_translation.sql','utf8');await db.exec(sql);await db.exec(sql);
 await owner('save_auto_translation',{enabled:true,excluded:[]});await owner('save_translation_language',{target:'ko'});
 const notice=id(99201),mid=99202;await internal('messages',{items:[{id:mid,bookingId:10,propertyId:100,source:'guest',message:'Where is the entrance?',time:new Date().toISOString()}]});
 await db.query('update omg_private.online_messages set notice_id=$1 where property_id=$2 and id=$3',[notice,p1,mid]);
 const ctl=async(a,d)=>(await db.query('select public.translation_control($1,$2,null,$3) v',[a,p1,JSON.stringify(d)])).rows[0].v;
 const j=await ctl('claim',{message_id:mid,target:'ko',direction:'incoming',automatic:true});assert(j.lease);await ctl('finish',{id:j.id,lease:j.lease,text:'입구는 어디인가요?',source_language:'en',charged:true});
 const read=async()=>(await db.query('select omg_private.guest_popup_online($1,$2) v',[p1,notice])).rows[0].v;
 let c=await read();assert.equal(c.translation,'입구는 어디인가요?');assert.equal(c.original,'Where is the entrance?');
 await owner('save_auto_translation',{enabled:true,excluded:['en']});assert(!('translation'in await read()),'new exclusions hide previously cached translations');
 await owner('save_auto_translation',{enabled:false,excluded:[]});assert(!('translation'in await read()));
 assert.equal((await db.query("select has_function_privilege('anon','public.online_notice_translation(uuid,uuid)','execute') ok")).rows[0].ok,false);
 console.log('Popup translation DB: exact message/body/target provenance, enabled state, exclusions and private access passed');
};
