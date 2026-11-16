/* Aggregate response sizes only. Never record tokens, message bodies or guest names. */
(function(){
 const key='oms-transfer-totals-v1';let totals={};
 try{totals=JSON.parse(sessionStorage.getItem(key)||'{}');}catch{}
 const day=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 function record(name,bytes,failed){const d=day();if(totals.day!==d)totals={day:d,endpoints:{}};const item=totals.endpoints[name]||{requests:0,decodedBytes:0,failures:0};item.requests++;item.decodedBytes+=bytes;item.failures+=failed?1:0;totals.endpoints[name]=item;try{sessionStorage.setItem(key,JSON.stringify(totals));}catch{}}
 async function fetchRpc(input,init={}){
  const url=String(input instanceof Request?input.url:input),name=/\/rest\/v1\/rpc\/([a-z0-9_]+)/.exec(url)?.[1];
  if(!name)return fetch(input,init);
  const controller=new AbortController(),signal=init.signal||(input instanceof Request?input.signal:null),abort=()=>controller.abort();
  if(signal?.aborted)abort();signal?.addEventListener('abort',abort,{once:true});
  const short=['get_app_session','get_work_app_config','home_message_summary','home_cleaning_summary','list_working_employees'].includes(name);
  const timeout=setTimeout(abort,short?15000:55000);
  let handedOff=false;const cleanup=()=>{clearTimeout(timeout);signal?.removeEventListener('abort',abort);};
  try{const response=await fetch(input,{...init,signal:controller.signal});
   // Count decoded response bytes as a local diagnostic, not a billing estimate.
   const reader=response.clone().body?.getReader();if(reader){handedOff=true;(async()=>{let bytes=0;try{for(;;){const chunk=await reader.read();if(chunk.done)break;bytes+=chunk.value.byteLength;}record(name,bytes,!response.ok);}catch{record(name,bytes,true);}finally{reader.releaseLock();cleanup();}})();}
   else record(name,0,!response.ok);
   return response;
  }catch(error){record(name,0,true);throw error;}finally{if(!handedOff)cleanup();}
 }
 window.OMSUsage={snapshot:()=>JSON.parse(JSON.stringify(totals)),clear(){totals={};sessionStorage.removeItem(key);}};
 window.OMSRpcFetch=fetchRpc;
})();
