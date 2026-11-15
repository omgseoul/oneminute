// A dedicated inventory reader: no booking, message, notification or settings writes.
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE='https://beds24.com/api/v2';
export function createRoomImportHandler({env,fetcher=fetch}){
 async function rpc(name,data){const key=env('SUPABASE_SERVICE_ROLE_KEY'),r=await fetcher(env('SUPABASE_URL')+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(data),signal:AbortSignal.timeout(15000)}),v=await r.json();if(!r.ok)throw Error(v.code==='P0001'?v.message:'객실정보를 불러오지 못했습니다.');return v;}
 const internal=(action,property,data={})=>rpc('online_internal',{p_action:action,p_property:property,p_data:data});
 return async req=>{
  const origin=req.headers.get('origin'),allowed=['https://omgworks24.com','https://www.omgworks24.com','https://omgseoul.github.io'],headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};if(allowed.includes(origin))headers['Access-Control-Allow-Origin']=origin;const reply=(body,status=200)=>new Response(JSON.stringify(body),{headers,status});
  if(origin&&!allowed.includes(origin))return reply({ok:false},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type, apikey, authorization'}});
  if(req.method!=='POST')return reply({ok:false},405);
  try{
   const raw=await req.text();if(raw.length>4000)return reply({ok:false},413);const b=JSON.parse(raw),property=b.data?.property_id;
   if(!UUID.test(b.access_token||'')||property&&!UUID.test(property))return reply({ok:false,message:'관리자 로그인을 확인해주세요.'},401);
   const auth=await rpc('online_room_import_auth',{p_token:b.access_token,p_property:property||null}),p=auth.property_id,c=await internal('credentials',p);
   if(!c.secret?.refreshToken||!c.beds_property_id||Number(c.beds_property_id)!==Number(auth.beds_property_id))throw Error('온라인관리 메뉴에서 Beds24 숙소 연결을 확인해주세요.');
   async function api(path,credentials){const gate=await rpc('online_sync_control',{p_action:'check',p_property:p,p_data:{}});if(gate.skip)throw Error('Beds24 요청 제한입니다. 잠시 후 다시 불러와주세요.');const r=await fetcher(BASE+path,{headers:{accept:'application/json',...credentials},signal:AbortSignal.timeout(20000)});if(r.status===429){await rpc('online_sync_control',{p_action:'cooldown',p_property:p,p_data:{seconds:300}});throw Error('Beds24 요청 제한입니다. 잠시 후 다시 불러와주세요.');}if(!r.ok)throw Error('Beds24 객실 조회 권한을 확인해주세요.');const v=await r.json();if(v.success===false)throw Error('Beds24 객실정보 조회를 완료하지 못했습니다.');return v;}
   if(!c.secret.token||c.secret.expiresAt<Date.now()+60000){const v=await api('/authentication/token',{refreshToken:c.secret.refreshToken});if(!v.token)throw Error('Beds24 연결을 확인해주세요.');c.secret={...c.secret,token:v.token,expiresAt:Date.now()+Math.max(60,Number(v.expiresIn)||3600)*1000};await internal('token',p,{secret:c.secret});}
   for(let page=1;page<=10;page++){
    const v=await api('/properties?includeAllRooms=true&includeUnitDetails=true&page='+page,{token:c.secret.token});if(!Array.isArray(v.data))throw Error('객실정보 응답을 확인해주세요.');const selected=v.data.find(x=>Number(x.id)===Number(c.beds_property_id));
    if(selected)return reply({ok:true,property_id:p,property_name:String(selected.name||''),room_types:(selected.roomTypes||[]).map(r=>({name:String(r.name||''),units:(r.units||[]).map(u=>({name:String(u.name||'')}))}))});
    if(v.pages?.nextPageExists!==true)break;
   }
   throw Error('연결된 숙소의 객실 조회 권한을 확인해주세요.');
  }catch(e){return reply({ok:false,message:e instanceof SyntaxError?'응답 형식을 확인해주세요.':e.message},400);}
 };
}
