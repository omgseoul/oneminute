// Outbound-only SMTP mail. Guests reply through a scoped webchat link.
export const GUEST_EMAIL_FROM='notifications@omgworks24.com';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LINK=/^[a-f0-9]{64}$/;
const PHOTO_LIMIT=4*1024*1024;
const ORIGINS=new Set(['https://omgworks24.com','https://www.omgworks24.com','https://omgseoul.github.io']);
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function mailbox(value){return typeof value==='string'&&/^[^\s<>@,]+@[^\s<>@,]+\.[^\s<>@,]+$/.test(value)?value:null;}
export function emailPayload(job){
 const from=GUEST_EMAIL_FROM;
 const p=job.payload;
 if(!LINK.test(p.link_token)||!mailbox(p.to)||!mailbox(from)||!UUID.test(job.id))throw Error('invalid_job');
 const name=String(p.name||'OMG WORKS').replace(/[\r\n<>"\\]/g,' ').trim().slice(0,100);
 const link='https://omgworks24.com/guest-chat.html#reply='+p.link_token;
 const body=String(p.body||'')+(p.asset_path?'\n[사진 첨부 / Photo attached]':'');
 const intro='숙소 채팅으로 문의하신 내용에 답변드립니다.';
 const introEn='Here is the reply to your message in our guest chat.';
 return {from:{name,address:from},to:p.to,subject:`${name} — 문의하신 내용에 대한 답변 / Guest chat reply`,
 messageId:`<guest-${job.id}@${from.split('@')[1]}>`,
 text:`${name}\n\n${intro}\n${introEn}\n\n${body}\n\n채팅방에서 답변하기 / Reply in guest chat:\n${link}\n\n이 이메일은 숙소 채팅의 답변 알림입니다. 이메일 회신은 확인하지 않습니다.\nThis is a guest chat reply notification. Email replies are not monitored.`,
 html:`<!doctype html><html><head><meta charset="utf-8"></head><body style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6;color:#222;background:#fff"><p><strong>${escape(name)}</strong></p><p>${intro}<br>${introEn}</p><div style="white-space:pre-wrap">${escape(body)}</div><p><a href="${escape(link)}">채팅방에서 답변하기 / Reply in guest chat</a></p><p style="font-size:13px;color:#555">이 이메일은 숙소 채팅의 답변 알림입니다. 이메일 회신은 확인하지 않습니다.<br>This is a guest chat reply notification. Email replies are not monitored.</p></body></html>`,
 headers:{'Auto-Submitted':'auto-generated','X-Auto-Response-Suppress':'All'}};
}
export function photoMime(b){
 if(b[0]===255&&b[1]===216&&b[2]===255)return 'image/jpeg';
 if(b.slice(0,8).join(',')==='137,80,78,71,13,10,26,10')return 'image/png';
 const d=new TextDecoder();if(d.decode(b.slice(0,4))==='RIFF'&&d.decode(b.slice(8,12))==='WEBP')return 'image/webp';return null;
}
async function bytesLimited(response,limit){
 if(Number(response.headers.get('content-length'))>limit)throw Error('file_too_large');
 const reader=response.body.getReader(),chunks=[];let total=0;
 try{for(;;){const {done,value}=await reader.read();if(done)break;total+=value.length;if(total>limit)throw Error('file_too_large');chunks.push(value);}}
 catch(e){await reader.cancel();throw e;}
 const bytes=new Uint8Array(total);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;
}
function base64(bytes){let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s);}
export function createGuestEmailHandler({env,sendMail,fetcher=fetch,cryptoApi=crypto}){
 const base=()=>env('SUPABASE_URL'),service=()=>env('SUPABASE_SERVICE_ROLE_KEY');
 const dbHeaders=()=>({apikey:service(),Authorization:'Bearer '+service(),'Content-Type':'application/json'});
 const rpc=async(name,body={})=>{
  const r=await fetcher(base()+'/rest/v1/rpc/'+name,{method:'POST',headers:dbHeaders(),body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
  if(!r.ok){const e=new Error('database_'+r.status);if(name==='open_guest_email'){const v=await r.json();if(v.code==='P0001')e.userMessage=v.message;}throw e;}
  return r.status===204?null:r.json();
 };
 async function dispatch(){
  const jobs=await rpc('claim_guest_emails');let sent=0,failed=0;
  for(const job of jobs){let smtpStarted=false;
   try{
    const payload=emailPayload(job);
    if(job.payload.asset_path){
     const path=job.payload.asset_path.split('/').map(encodeURIComponent).join('/');
     const r=await fetcher(base()+'/storage/v1/object/authenticated/guest-support/'+path,{headers:dbHeaders(),signal:AbortSignal.timeout(15000)});
     if(!r.ok)throw Error('photo_unavailable');const bytes=await bytesLimited(r,PHOTO_LIMIT),mime=photoMime(bytes);
     if(!mime)throw Error('unsupported_photo');
     payload.attachments=[{filename:'photo.'+({'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[mime]),content:base64(bytes),encoding:'base64'}];
    }
    smtpStarted=true;
    const result=await sendMail(payload);
    if(!result.accepted?.length)throw Error('smtp_not_accepted');
    await rpc('finish_guest_email',{p_id:job.id,p_lease:job.lease,p_provider:payload.messageId});sent++;
   }catch(e){failed++;
    await rpc(smtpStarted?'fail_guest_email':'finish_guest_email',{p_id:job.id,p_lease:job.lease,p_error:smtpStarted?'smtp_delivery_check_required':'delivery_retry'});
   }
  }
  return {ok:true,sent,failed};
 }
 return async req=>{
  const origin=req.headers.get('origin'),headers={'Cache-Control':'no-store','Vary':'Origin'};
  if(ORIGINS.has(origin))headers['Access-Control-Allow-Origin']=origin;
  const reply=(body,status=200)=>Response.json(body,{status,headers});
  if(origin&&!ORIGINS.has(origin))return reply({ok:false},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type, apikey'}});
  if(req.method!=='POST')return reply({ok:false},405);
  const action=new URL(req.url).pathname.split('/').pop();
  if(!['dispatch','open'].includes(action))return reply({ok:false},404);
  const workerToken=req.headers.get('x-worker-secret');
  const workerSecret=env('GUEST_EMAIL_WORKER_SECRET');
  if(action==='dispatch'&&(!workerToken||(workerSecret&&workerToken!==workerSecret)))return reply({ok:false},401);
  if(!base()||!service())return reply({ok:false,message:'서버 연결 설정이 필요합니다.'},503);
  try{
   if(action==='dispatch'){
    if(!workerSecret){
     if(!/^[a-f0-9]{64}$/.test(workerToken))return reply({ok:false},401);
     if(await rpc('verify_guest_email_worker',{p_secret:workerToken})!==true)return reply({ok:false},401);
    }
    if(!env('SMTP_HOST')||!env('SMTP_USER')||!env('SMTP_PASSWORD'))return reply({ok:false,error:'smtp_not_configured'},503);
    return reply(await dispatch());
   }
   const raw=new TextDecoder().decode(await bytesLimited(req,2048));const body=JSON.parse(raw);
   if(!LINK.test(body.token||''))return reply({ok:false,message:'유효하지 않은 답변 링크입니다.'},400);
   return reply(await rpc('open_guest_email',{p_link:body.token,p_new_token:cryptoApi.randomUUID()}));
  }catch(e){return reply({ok:false,message:e.userMessage||'연결하지 못했습니다. 잠시 후 이메일의 답변하기를 다시 눌러주세요.'},e.userMessage?400:503);}
 };
}
