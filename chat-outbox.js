/* Durable per-room lanes. Failed sends wait for an explicit retry. */
(function(){
 window.OMSChatOutbox={async open(scope,send,changed){
  const db=await new Promise((resolve,reject)=>{const q=indexedDB.open('oms-chat-outbox',1);q.onupgradeneeded=()=>q.result.createObjectStore('messages',{keyPath:'client_id'});q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  let entries=[],closed=false;const active=new Set();
  function transaction(mode,fn){return new Promise((resolve,reject)=>{const tx=db.transaction('messages',mode);fn(tx.objectStore('messages'));tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});}
  const all=await new Promise((resolve,reject)=>{const q=db.transaction('messages').objectStore('messages').getAll();q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  entries=all.filter(e=>e.scope===scope).sort((a,b)=>a.created_at.localeCompare(b.created_at));
  async function save(item){await transaction('readwrite',s=>s.put(item));}
  for(const item of entries)if(item.status==='sending'){item.status='failed';item.error='전송이 중단되었습니다. 재시도를 눌러주세요.';await save(item);}
  const lane=item=>(item.photo?'media:':'text:')+item.peer;
  async function deliver(item,key){
   try{await save(item);changed();const result=await send(item);item.status='sent';item.message=result.message;item.message_id=result.message_id;await save(item);}
   catch(error){item.status='failed';item.error=error.message;item.blocked=true;await save(item).catch(()=>{});}
   finally{active.delete(key);if(!closed){changed();pump();}}
  }
  function pump(){
   if(closed||navigator.onLine===false)return;
   for(const item of entries){
    if(item.status!=='queued')continue;
    const key=lane(item),type=item.photo?'media:':'text:',limit=2;
    if(active.has(key)||[...active].filter(k=>k.startsWith(type)).length>=limit)continue;
    active.add(key);item.status='sending';deliver(item,key);
   }
  }
  const api={
   items(peer){return entries.filter(e=>e.peer===peer);},
   async enqueue(item){const value={...item,scope,status:'queued',created_at:new Date().toISOString(),client_id:crypto.randomUUID()};await save(value);entries.push(value);changed();pump();return value;},
   async acknowledge(messages){const ids=new Set(messages.map(m=>m.client_id).filter(Boolean)),server=new Set(messages.map(m=>m.id));const done=entries.filter(e=>e.status==='sent'&&(ids.has(e.client_id)||server.has(e.message_id)));if(!done.length)return;await transaction('readwrite',s=>done.forEach(e=>s.delete(e.client_id)));entries=entries.filter(e=>!done.includes(e));changed();},
   async retry(id){const item=entries.find(e=>e.client_id===id&&e.status==='failed');if(!item)return;item.status='queued';item.blocked=false;try{await save(item);}catch(error){item.status='failed';throw error;}changed();pump();},
   async cancel(id){const item=entries.find(e=>e.client_id===id&&['queued','failed'].includes(e.status));if(!item)return;item.status='cancelling';try{await transaction('readwrite',s=>s.delete(id));entries=entries.filter(e=>e!==item);}catch(error){item.status='failed';throw error;}changed();pump();},
   pump,close(){closed=true;window.removeEventListener('online',pump);}
  };
  window.addEventListener('online',pump);changed();pump();return api;
 }};
})();
