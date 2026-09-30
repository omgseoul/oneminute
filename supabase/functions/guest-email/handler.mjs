// Server-only mail bridge. Never accept a destination or room ID from a webhook body.
export const REPLY_DOMAIN='reply.omgworks24.com';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHOTO_LIMIT=4*1024*1024;
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function mailbox(value){
 const s=String(value||'').trim();if(/[\r\n]/.test(s))return null;
 const address=(s.match(/<([^<>]+)>$/)?.[1]||s).trim().toLowerCase();
 return /^[^\s<>@,]+@[^\s<>@,]+\.[^\s<>@,]+$/.test(address)?address:null;
}
export function replyAlias(recipients){
 const aliases=[...new Set((Array.isArray(recipients)?recipients:[]).map(mailbox).filter(Boolean)
 .map(s=>s.match(/^reply-([a-f0-9]{32})@reply\.omgworks24\.com$/)?.[1]).filter(Boolean))];
 if(aliases.length!==1)return null;
 return aliases[0].replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/,'$1-$2-$3-$4-$5');
}
export function replyText(email){
 let text=email.text;
 if(!text&&email.html){
  text=email.html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi,'').replace(/<br\s*\/?\s*>/gi,'\n')
   .replace(/<\/(p|div|tr|li|h[1-6])>/gi,'\n').replace(/<[^>]*>/g,'')
   .replace(/&(?:amp|lt|gt|quot|apos|nbsp|#39);/g,s=>({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&apos;':"'",'&#39;':"'",'&nbsp;':' '}[s]));
 }
 const original=String(text||'').replace(/\r\n?/g,'\n').replace(/\u0000/g,'').trim();
 // Only remove well-known reply separators. Unrecognised formats remain readable.
 const lines=original.split('\n'),cut=lines.findIndex((s,i)=>i>0&&(/^-{2,}\s*(Original Message|원본 메시지)/i.test(s)||/^On .+wrote:\s*$/.test(s)||/님이\s*작성:\s*$/.test(s)));
 const clean=(cut<0?original:lines.slice(0,cut).join('\n')).trim();
 return clean.length>18000?clean.slice(0,18000)+'\n[긴 이메일의 뒷부분은 생략되었습니다.]':clean;
}
export function emailPayload(job){
 const p=job.payload;if(!/^[a-f0-9]{32}$/.test(p.alias)||!mailbox(p.to)||!UUID.test(p.slug))throw Error('invalid_job');
 const name=String(p.name||'OMG WORKS').replace(/[\r\n<>"\\]/g,' ').trim().slice(0,100);
 const address=`reply-${p.alias}@${REPLY_DOMAIN}`,link='https://omgworks24.com/guest-chat.html?p='+p.slug;
 const body=String(p.body||'')+(p.asset_path?'\n[사진 첨부 / Photo attached]':'');
 return {from:`${name} <${address}>`,reply_to:address,to:[p.to],subject:`${name} · 게스트 대화`,
  text:`${name}\n\n${body}\n\n이 이메일에 답장하면 숙소 채팅으로 전달됩니다.\nReply to this email to message your host.\n\n웹채팅 / Open chat: ${link}`,
  html:`<!doctype html><html><body style="margin:0;background:#f3f6fb;font-family:Arial,sans-serif;color:#193349"><div style="max-width:560px;margin:24px auto;background:white;border-radius:24px;padding:32px"><p style="font-size:13px;color:#718397">OMG WORKS</p><h1 style="font-size:24px">${escape(name)}</h1><div style="padding:24px;background:#f3f6fb;border-radius:18px;font-size:17px;line-height:1.7;white-space:pre-wrap">${escape(body)}</div><p style="font-size:14px;line-height:1.7;color:#63758a">이 이메일에 답장하면 숙소 채팅으로 전달됩니다.<br>Reply to this email to message your host.</p><a href="${escape(link)}" style="display:inline-block;padding:14px 24px;border-radius:14px;background:#286bc0;color:#fff;text-decoration:none">웹채팅 열기 · Open chat</a></div></body></html>`,
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
export function createGuestEmailHandler({env,verifyWebhook,fetcher=fetch,wait=ms=>new Promise(r=>setTimeout(r,ms))}){
 const base=()=>env('SUPABASE_URL'),service=()=>env('SUPABASE_SERVICE_ROLE_KEY');
 const dbHeaders=()=>({apikey:service(),Authorization:'Bearer '+service(),'Content-Type':'application/json'});
 const rpc=async(name,body={})=>{
  const r=await fetcher(base()+'/rest/v1/rpc/'+name,{method:'POST',headers:dbHeaders(),body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
  if(!r.ok)throw Error('database_'+r.status);return r.status===204?null:r.json();
 };
 const provider=async(path,options={})=>{
  const r=await fetcher('https://api.resend.com'+path,{...options,headers:{Authorization:'Bearer '+env('RESEND_API_KEY'),'Content-Type':'application/json',...options.headers},signal:AbortSignal.timeout(20000)});
  if(!r.ok)throw Error('provider_'+r.status);return r.json();
 };
 async function dispatch(){
  const jobs=await rpc('claim_guest_emails');let sent=0,failed=0;
  for(const job of jobs){
   try{
    const payload=emailPayload(job);
    if(job.payload.asset_path){
     const path=job.payload.asset_path.split('/').map(encodeURIComponent).join('/');
     const r=await fetcher(base()+'/storage/v1/object/authenticated/guest-support/'+path,{headers:dbHeaders(),signal:AbortSignal.timeout(15000)});
     if(!r.ok)throw Error('photo_unavailable');const bytes=await bytesLimited(r,PHOTO_LIMIT),mime=photoMime(bytes);
     if(!mime)throw Error('unsupported_photo');
     payload.attachments=[{filename:'photo.'+({'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[mime]),content:base64(bytes)}];
    }
    const result=await provider('/emails',{method:'POST',headers:{'Idempotency-Key':'guest-message/'+job.id},body:JSON.stringify(payload)});
    if(!result.id)throw Error('provider_missing_id');
    await rpc('finish_guest_email',{p_id:job.id,p_lease:job.lease,p_provider:result.id});sent++;
   }catch(e){failed++;await rpc('finish_guest_email',{p_id:job.id,p_lease:job.lease,p_error:/^[a-z_]+(?:_\d+)?$/.test(e.message)?e.message:'delivery_retry'});}
   await wait(550);
  }
  return {ok:true,sent,pending_retry:failed};
 }
 async function receive(event){
  if(event.type!=='email.received')return {ok:true,ignored:true};
  const id=event.data?.email_id;if(!UUID.test(id||''))return {ok:true,ignored:true};
  const email=await provider('/emails/receiving/'+id+'?html_format=cid');
  const alias=replyAlias(email.received_for?.length?email.received_for:email.to),sender=mailbox(email.from);
  if(!alias||!sender||sender.endsWith('@'+REPLY_DOMAIN))return {ok:true,ignored:true};
  const auth=email.authentication||{};
  if(auth.dmarc==='fail'||!(auth.dmarc==='pass'||auth.dkim==='pass'))return {ok:true,ignored:true,reason:'sender_authentication'};
  const headers=Object.fromEntries(Object.entries(email.headers||{}).map(([k,v])=>[k.toLowerCase(),String(v).toLowerCase()]));
  if((headers['auto-submitted']&&headers['auto-submitted']!=='no')||/bulk|list|junk/.test(headers.precedence||''))return {ok:true,ignored:true};
  const route=await rpc('resolve_guest_email',{p_alias:alias,p_sender:sender});
  if(!route)return {ok:true,ignored:true};
  let body=replyText(email);const assets=[];let omitted=0;
  // At most five photos, each 4MB. Provider URLs only; no links from email HTML are fetched.
  for(const attachment of email.attachments||[]){
   if(!UUID.test(attachment.id||'')||!['image/jpeg','image/png','image/webp'].includes(attachment.content_type)||attachment.size>PHOTO_LIMIT||assets.length>=5){omitted++;continue;}
   await wait(550);
   const detail=await provider('/emails/receiving/'+id+'/attachments/'+attachment.id);
   const url=new URL(detail.download_url);
   if(url.protocol!=='https:'||url.hostname!=='inbound-cdn.resend.com'||url.port||url.username||url.password)throw Error('unexpected_attachment_host');
   const r=await fetcher(url.href,{redirect:'error',signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('attachment_unavailable');
   let bytes;try{bytes=await bytesLimited(r,PHOTO_LIMIT);}catch(e){if(e.message!=='file_too_large')throw e;omitted++;continue;}
   const mime=photoMime(bytes);if(!mime){omitted++;continue;}
   const path=`${route.property_id}/${route.room_id}/email/${id}/${attachment.id}`;
   const stored=await fetcher(base()+'/storage/v1/object/guest-support/'+path,{method:'POST',headers:{...dbHeaders(),'Content-Type':mime,'x-upsert':'true'},body:bytes,signal:AbortSignal.timeout(15000)});
   if(!stored.ok)throw Error('attachment_storage');assets.push({path,mime});
  }
  if(omitted)body+=`\n[이메일 첨부 ${omitted}개는 지원 형식 또는 용량 제한으로 표시할 수 없습니다.]`;
  if(!body.trim()&&!assets.length)return {ok:true,ignored:true};
  const result=await rpc('receive_guest_email',{p_provider:id,p_alias:alias,p_sender:sender,p_body:body,p_assets:assets});
  if(result.event_id){
   const r=await fetcher(base()+'/functions/v1/dispatch-notification/guest-chat',{method:'POST',headers:{'Content-Type':'application/json','x-webhook-secret':env('PUSH_ADMIN_SECRET')||''},body:JSON.stringify({event_id:result.event_id}),signal:AbortSignal.timeout(20000)});
   if(!r.ok)throw Error('push_retry');
  }
  return {ok:true};
 }
 return async req=>{
  const reply=(body,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
  if(req.method!=='POST')return reply({ok:false},405);
  const action=new URL(req.url).pathname.split('/').pop();
  if(!['dispatch','webhook'].includes(action))return reply({ok:false},404);
  if(action==='dispatch'&&(!env('GUEST_EMAIL_WORKER_SECRET')||req.headers.get('x-worker-secret')!==env('GUEST_EMAIL_WORKER_SECRET')))return reply({ok:false},401);
  if(!base()||!service()||!env('RESEND_API_KEY'))return reply({ok:false,error:'not_configured'},503);
  try{
   if(action==='dispatch')return reply(await dispatch());
   if(!env('RESEND_WEBHOOK_SECRET'))return reply({ok:false,error:'not_configured'},503);
   if(Number(req.headers.get('content-length'))>65536)return reply({ok:false},413);
   const raw=new TextDecoder().decode(await bytesLimited(req,65536));let event;
   try{event=await verifyWebhook(raw,Object.fromEntries(req.headers),env('RESEND_WEBHOOK_SECRET'));}catch{return reply({ok:false},401);}
   return reply(await receive(event));
  }catch(e){return reply({ok:false,error:e.message==='file_too_large'?'payload_limit':'retry_later'},e.message==='file_too_large'?413:503);}
 };
}
