// Isolated gateway: custom app sessions and opaque guest tokens stay server-validated.
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIONS=new Set(['portal','start','settings','save_settings','save_preferences','rooms','messages','send','claim','release','close','reopen','read','retry_events']);
const ORIGINS=new Set(['https://omgworks24.com','https://www.omgworks24.com','https://omgseoul.github.io']);
const LIMIT=4194304;
export function createGuestSupportHandler({env,fetcher=fetch,cryptoApi=crypto}){
 const base=()=>env('SUPABASE_URL'),key=()=>env('SUPABASE_SERVICE_ROLE_KEY');
 const headers=()=>({apikey:key(),Authorization:'Bearer '+key()});
 async function rpc(action,data,token,guest,ip=''){
  const r=await fetcher(base()+'/rest/v1/rpc/guest_support_rpc',{method:'POST',headers:{...headers(),'Content-Type':'application/json'},body:JSON.stringify({p_action:action,p_data:data,p_token:token||null,p_guest_token:guest||null,p_ip_hash:ip}),signal:AbortSignal.timeout(12000)});
  const v=await r.json();if(!r.ok){const e=new Error(v.code==='P0001'?v.message:'요청을 처리하지 못했습니다. 잠시 후 다시 시도해주세요.');e.status=400;throw e;}return v;
 }
 async function dispatch(id){try{
  const r=await fetcher(base()+'/functions/v1/dispatch-notification/guest-chat',{method:'POST',headers:{'Content-Type':'application/json','x-webhook-secret':env('PUSH_ADMIN_SECRET')||''},body:JSON.stringify({event_id:id}),signal:AbortSignal.timeout(20000)});return r.ok?'sent':'pending';
 }catch{return 'pending';}}
 async function sign(value){
  if(!value.assets?.length)return value;
  const r=await fetcher(base()+'/storage/v1/object/sign/guest-support',{method:'POST',headers:{...headers(),'Content-Type':'application/json'},body:JSON.stringify({expiresIn:900,paths:value.assets.map(a=>a.path)}),signal:AbortSignal.timeout(10000)});
  if(!r.ok)throw new Error('첨부파일을 불러오지 못했습니다. 다시 열어주세요.');
  const urls=await r.json();value.assets=value.assets.map(a=>{const s=urls.find(x=>x.path===a.path);if(!s?.signedURL)throw new Error('첨부파일을 불러오지 못했습니다.');return {id:a.id,mime:a.mime,url:base()+'/storage/v1'+s.signedURL};});return value;
 }
 return async req=>{
  const origin=req.headers.get('origin');const cors={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
  if(ORIGINS.has(origin))cors['Access-Control-Allow-Origin']=origin;
  const reply=(v,status=200)=>new Response(JSON.stringify(v),{status,headers:cors});
  if(origin&&!ORIGINS.has(origin))return reply({ok:false,message:'허용되지 않은 접속입니다.'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...cors,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type, apikey, authorization'}});
  if(req.method!=='POST')return reply({ok:false},405);
  try{
   if(!base()||!key())throw new Error('설정이 완료되지 않았습니다.');
   if(Number(req.headers.get('content-length')||0)>LIMIT+65536)return reply({ok:false,message:'파일은 4MB 이하로 선택해주세요.'},413);
   const multipart=(req.headers.get('content-type')||'').startsWith('multipart/form-data');
   let body,file;
   if(multipart){const f=await req.formData();body=JSON.parse(String(f.get('request')));file=f.get('file');}
   else{const raw=await req.text();if(raw.length>64000)return reply({ok:false},413);body=JSON.parse(raw);}
   if(!body||typeof body!=='object')return reply({ok:false},400);
   const {action,data={},access_token:token,guest_token:guest}=body;
   if(action==='cleanup_files'){
    if(typeof body.platform_token!=='string'||!UUID.test(data.job_id||''))return reply({ok:false,message:'운영자 로그인이 필요합니다.'},401);
    const userResponse=await fetcher(base()+'/auth/v1/user',{headers:{apikey:key(),Authorization:'Bearer '+body.platform_token},signal:AbortSignal.timeout(10000)});
    if(!userResponse.ok)return reply({ok:false,message:'운영자 로그인이 만료되었습니다.'},401);
    const user=await userResponse.json();if(!UUID.test(user.id||''))return reply({ok:false},401);
    const work=async(done=[])=>{const r=await fetcher(base()+'/rest/v1/rpc/platform_message_storage_worker',{method:'POST',headers:{...headers(),'Content-Type':'application/json'},body:JSON.stringify({p_user:user.id,p_job:data.job_id,p_done:done}),signal:AbortSignal.timeout(10000)});if(!r.ok)throw new Error('정리 권한 또는 작업 상태를 확인해주세요.');return r.json();};
    const job=await work();if(job.files.length){
     const r=await fetcher(base()+'/storage/v1/object/guest-support',{method:'DELETE',headers:{...headers(),'Content-Type':'application/json'},body:JSON.stringify({prefixes:job.files.map(f=>f.object_path)}),signal:AbortSignal.timeout(20000)});
     if(!r.ok)throw new Error('사진 정리가 중단되었습니다. 다시 시도하면 이어서 처리합니다.');
     const next=await work(job.files.map(f=>f.asset_id));return reply({ok:true,status:next.status,remaining:next.files.length});
    }return reply({ok:true,status:job.status,remaining:0});
   }
   if((token&&!UUID.test(token))||(guest&&!UUID.test(guest)))return reply({ok:false,message:'다시 로그인해주세요.'},401);
   if(action==='upload'&&multipart){
    if(!file||typeof file.arrayBuffer!=='function'||file.size>LIMIT||file.size<8)throw new Error('4MB 이하의 사진 또는 PDF를 선택해주세요.');
    const bytes=new Uint8Array(await file.arrayBuffer());
    const mime=bytes[0]===255&&bytes[1]===216&&bytes[2]===255?'image/jpeg':bytes.slice(0,8).join(',')==='137,80,78,71,13,10,26,10'?'image/png':new TextDecoder().decode(bytes.slice(0,4))==='RIFF'&&new TextDecoder().decode(bytes.slice(8,12))==='WEBP'?'image/webp':new TextDecoder().decode(bytes.slice(0,5))==='%PDF-'?'application/pdf':null;
    if(!mime||(data.room_id&&mime==='application/pdf'))throw new Error('사진은 JPG·PNG·WEBP, 안내파일은 PDF도 가능합니다.');
    const asset=await rpc('upload_begin',{room_id:data.room_id||null,mime},token,guest);
    const stored=await fetcher(base()+'/storage/v1/object/guest-support/'+asset.path,{method:'POST',headers:{...headers(),'Content-Type':mime},body:bytes,signal:AbortSignal.timeout(25000)});
    if(!stored.ok)throw new Error('사진 업로드에 실패했습니다. 다시 선택해주세요.');
    await rpc('upload_finish',{room_id:data.room_id||null,asset_id:asset.asset_id},token,guest);
    return reply(await sign({ok:true,asset_id:asset.asset_id,assets:[{id:asset.asset_id,path:asset.path,mime}]}));
   }
   if(!ACTIONS.has(action))return reply({ok:false,message:'지원하지 않는 요청입니다.'},400);
   let ip='';if(action==='start'){
    const addr=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim();
    if(!addr)throw new Error('접속을 확인하지 못했습니다. 다시 시도해주세요.');
    ip=[...new Uint8Array(await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode(key()+':'+addr)))].map(x=>x.toString(16).padStart(2,'0')).join('');
   }
   const result=await sign(await rpc(action,data,token,guest,ip));
   if(result.event_id)result.push_state=await dispatch(result.event_id);
   if(action==='retry_events')await Promise.all((result.event_ids||[]).map(dispatch));
   return reply(result);
  }catch(e){return reply({ok:false,message:e instanceof SyntaxError?'요청 형식이 올바르지 않습니다.':e.message||'연결에 실패했습니다. 다시 시도해주세요.'},e.status||400);}
 };
}
