// Pure preview workflow: never calls guest_ai_finish, an outbox, or dispatch.
export async function runManualTest({id,job,rpc,fetcher,buildRequest,validateAnswer}){
 let result={estimated:false},attempted=false,received=false;
 try{
  const c=await rpc('guest_ai_credentials');if(!c?.enabled||!c?.key)throw Error('provider');
  const claim=await rpc('guest_ai_manual_test',{p_action:'attempt',p_data:{id}});if(!claim.start)return;
  attempted=true;
  const response=await fetcher('https://api.openai.com/v1/responses',{method:'POST',headers:{Authorization:'Bearer '+c.key,'Content-Type':'application/json'},body:JSON.stringify(buildRequest(job)),signal:AbortSignal.timeout(35000)});
  received=true;
  if(!response.ok){result.estimated=response.status>=500;throw Error('provider');}
  result.estimated=true;
  const out=await response.json(),u=out.usage;
  result={estimated:![u?.input_tokens,u?.output_tokens].every(n=>Number.isSafeInteger(n)&&n>=0),input_tokens:u?.input_tokens||0,output_tokens:u?.output_tokens||0,cached_tokens:u?.input_tokens_details?.cached_tokens||0,cache_write_tokens:u?.input_tokens_details?.cache_write_tokens||0};
  if(out.status!=='completed')throw Error('incomplete');
  const value=JSON.parse(out.output?.filter(x=>x.type==='message').flatMap(x=>x.content||[]).filter(x=>x.type==='output_text').map(x=>x.text).join(''));
  const verified=validateAnswer(value,job),ids=new Set(value.parts.flatMap(p=>p.sources));
  result={...result,...verified,parts:value.parts,sources:job.data.filter(r=>ids.has(String(r.id))),service_sources:[...ids].filter(id=>id.startsWith('service:')),room_number:job.room_number,question:job.history.at(-1).content};
 }catch{if(attempted&&!received)result.estimated=true;result.error='답변 생성 또는 매뉴얼 근거 검증에 실패했습니다. 다시 테스트해주세요.';}
 await rpc('guest_ai_manual_test',{p_action:'finish',p_data:{id,result}});
}
