/* Durable room lanes with explicit retry, pause and request cancellation. */
(function(){
 window.OMSChatOutbox={async open(scope,send,changed){
  const db=await new Promise((resolve,reject)=>{const q=indexedDB.open('oms-chat-outbox',1);q.onupgradeneeded=()=>q.result.createObjectStore('messages',{keyPath:'client_id'});q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  let entries=[],closed=false;const active=new Set(),transfers=new Map();
  function transaction(mode,fn){return new Promise((resolve,reject)=>{const tx=db.transaction('messages',mode);fn(tx.objectStore('messages'));tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});}
  const all=await new Promise((resolve,reject)=>{const q=db.transaction('messages').objectStore('messages').getAll();q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  entries=all.filter(e=>e.scope===scope).sort((a,b)=>a.created_at.localeCompare(b.created_at));
  let lastCreatedAt=entries.reduce((latest,e)=>Math.max(latest,Date.parse(e.created_at)||0),0);
  async function save(item){await transaction('readwrite',s=>s.put(item));}
  for(const item of entries)if(['sending','saving'].includes(item.status)){item.status='failed';item.error='전송이 중단되었습니다. 재시도를 눌러주세요.';await save(item);}
  const lane=item=>(item.photo?'media:':'text:')+item.peer;
  async function deliver(item,key,controller){
   try{
    await save(item);if(controller.signal.aborted)return;changed();
    const result=await send(item,{signal:controller.signal,onProgress:percent=>{if(controller.signal.aborted)return;item.upload_percent=percent;changed();}});
    if(!entries.includes(item))return;item.status='sent';item.message=result.message;item.message_id=result.message_id;await save(item);
   }catch(error){if(!controller.signal.aborted&&entries.includes(item)){item.status='failed';item.error=error.message;await save(item).catch(()=>{});}}
   finally{active.delete(key);transfers.delete(item.client_id);if(!closed){changed();pump();}}
  }
  function pump(){
   if(closed||navigator.onLine===false)return;
   for(const item of entries){
    if(item.status!=='queued')continue;
    const key=lane(item),type=item.photo?'media:':'text:';
    if(active.has(key)||[...active].filter(k=>k.startsWith(type)).length>=2)continue;
    active.add(key);item.status='sending';const controller=new AbortController();transfers.set(item.client_id,controller);deliver(item,key,controller);
   }
  }
  const api={
   items(peer){return entries.filter(e=>e.peer===peer&&e.status!=='cancelled');},
   async enqueue(item){lastCreatedAt=Math.max(Date.now(),lastCreatedAt+1);const value={...item,scope,status:'queued',created_at:new Date(lastCreatedAt).toISOString(),client_id:crypto.randomUUID()};await save(value);entries.push(value);changed();pump();return value;},
   async acknowledge(messages){const ids=new Set(messages.map(m=>m.client_id).filter(Boolean)),server=new Set(messages.map(m=>m.id));const done=entries.filter(e=>!transfers.has(e.client_id)&&(ids.has(e.client_id)||server.has(e.message_id)));if(!done.length)return;await transaction('readwrite',s=>done.forEach(e=>s.delete(e.client_id)));entries=entries.filter(e=>!done.includes(e));changed();},
   async retry(id){const item=entries.find(e=>e.client_id===id&&['failed','paused'].includes(e.status));if(!item)return;item.status='queued';delete item.upload_percent;try{await save(item);}catch(error){item.status='failed';throw error;}changed();pump();},
   async pause(id){const item=entries.find(e=>e.client_id===id&&['queued','sending','saving'].includes(e.status));if(!item)return;item.status='paused';transfers.get(id)?.abort();await save(item);changed();pump();},
   async cancel(id){const item=entries.find(e=>e.client_id===id&&e.status!=='sent');if(!item)return;item.status='cancelled';transfers.get(id)?.abort();try{await transaction('readwrite',s=>s.delete(id));entries=entries.filter(e=>e!==item);}catch(error){item.status='failed';throw error;}changed();pump();},
   pump,close(){closed=true;for(const controller of transfers.values())controller.abort();window.removeEventListener('online',pump);}
  };
  window.addEventListener('online',pump);changed();pump();return api;
 }};
})();
