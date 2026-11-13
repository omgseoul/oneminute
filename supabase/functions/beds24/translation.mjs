// Independent translation budget: no guest-AI credits or prompt access.
const decodeText=value=>value.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos);/gi,(match,entity)=>{const named={amp:'&',lt:'<',gt:'>',quot:'"',apos:"'"},key=entity.toLowerCase();if(key[0]!=='#')return named[key]||match;const n=parseInt(key.slice(key[1]==='x'?2:1),key[1]==='x'?16:10);return n>0&&n<=0x10ffff&&!(n>=0xd800&&n<=0xdfff)?String.fromCodePoint(n):match;});
export function createTranslation({rpc,fetcher}) {
 const ctl=(action,property=null,data={},user=null)=>rpc('translation_control',{p_action:action,p_property:property,p_user:user,p_data:data});
 async function validate(key){
  if(typeof key!=='string'||key.length<20||key.length>300)throw Error('Google Cloud Translation API 키를 확인해주세요.');
  let r;try{r=await fetcher('https://translation.googleapis.com/language/translate/v2',{method:'POST',headers:{'X-Goog-Api-Key':key,'Content-Type':'application/json'},body:JSON.stringify({q:'OK',target:'ko',format:'text',model:'nmt'}),signal:AbortSignal.timeout(15000)});}catch{throw Error('Google에 연결하지 못했습니다. 잠시 후 다시 확인해주세요.');}
  return r.ok?'valid':[400,401,403].includes(r.status)?'invalid':'unavailable';
 }
 async function save(property,key,user=null){
  const status=await validate(key);if(status!=='valid')throw Error(status==='invalid'?'유효하지 않은 키 또는 API 접근 불가 · Cloud Translation API 활성화와 키 제한사항을 확인해주세요.':'Google 연결·사용 한도를 확인해주세요.');
  return ctl(user?'platform_save':'save_key',property,{key},user);
 }
 async function check(property,user=null){
  const stored=await ctl(user?'platform_key':'personal_key',property,{},user);if(!stored.key)throw Error('등록된 번역 API 키가 없습니다.');
  const status=await validate(stored.key);return ctl(user?'platform_check_result':'personal_check_result',property,{status,fingerprint:stored.fingerprint},user);
 }
 async function translate(property,data){
  const job=await ctl('claim',property,data);
  if(job.cached)return {ok:true,...job};
  if(job.busy)throw Error('번역 처리 중입니다. 잠시 후 다시 확인해주세요.');
  if(job.limit_reached)throw Error('이번 달 남은 제공량으로 번역할 수 없습니다. 기본정보에 개인 번역 API 키를 등록해주세요.');
  if(job.unconfigured)throw Error('번역 API 연결이 필요합니다. 운영자 공용 연결 또는 기본정보의 개인 키를 확인해주세요.');
  let received=false,charged=true;
  try{
   const r=await fetcher('https://translation.googleapis.com/language/translate/v2',{method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':job.key},body:JSON.stringify({q:job.body,target:job.target,format:'text',model:'nmt'}),signal:AbortSignal.timeout(20000)});received=true;charged=r.ok||r.status>=500;
   if(!r.ok)throw Error('provider_failed');
   const v=await r.json(),translation=v.data?.translations?.[0];if(!translation?.translatedText)throw Error('empty_translation');
   const text=typeof translation.translatedText==='string'?decodeText(translation.translatedText):null,source_language=translation.detectedSourceLanguage||data.source_language||null;
   if(typeof text!=='string'||!text||text.length>20000)throw Error('invalid_translation');
   const result=await ctl('finish',property,{id:job.id,lease:job.lease,text,source_language,charged:true});
   return {ok:true,id:job.id,text,source_language,target:job.target,usage:result.usage};
  }catch{
   await ctl('finish',property,{id:job.id,lease:job.lease,charged:!received||charged});
   throw Error('번역하지 못했습니다. API 연결·사용 한도를 확인하고 잠시 후 다시 시도해주세요.');
  }
 }
 async function outgoing(property,data){
  if(typeof data.body!=='string'||!data.body.trim()||[...data.body.trim()].length>4000)throw Error('보낼 원문을 1~4,000자로 입력해주세요.');
  let target=data.target||'auto';
  if(target==='auto'){
   const m=await ctl('latest_guest',property,{booking_id:data.booking_id});if(!m.message_id)throw Error('언어를 확인할 수 있는 게스트 메시지가 없습니다. 보낼 언어를 직접 선택해주세요.');
   const incoming=await translate(property,{message_id:m.message_id,direction:'incoming'});target=incoming.source_language;
   if(!target)throw Error('상대방 언어를 확인하지 못했습니다. 보낼 언어를 직접 선택해주세요.');
  }
  const result=await translate(property,{direction:'outgoing',booking_id:data.booking_id,body:data.body,target});
  if([...result.text].length>4000)throw Error('번역문이 발송 한도인 4,000자를 넘었습니다. 원문을 줄여주세요.');
  return result;
 }
 return {ctl,save,check,translate,outgoing};
}
