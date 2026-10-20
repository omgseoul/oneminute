/* IndexedDB commits precede composer clearing. One ordered pump per tab; server
   client_id uniqueness also reconciles concurrent tabs and ambiguous timeouts. */
(function(){
 window.OMSChatOutbox={async open(scope,send,changed){
  const db=await new Promise((resolve,reject)=>{const q=indexedDB.open('oms-chat-outbox',1);q.onupgradeneeded=()=>q.result.createObjectStore('messages',{keyPath:'client_id'});q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  let entries=[],busy=false,closed=false,timer;
  function transaction(mode,fn){return new Promise((resolve,reject)=>{const tx=db.transaction('messages',mode);fn(tx.objectStore('messages'));tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});}
  const all=await new Promise((resolve,reject)=>{const q=db.transaction('messages').objectStore('messages').getAll();q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  entries=all.filter(e=>e.scope===scope).sort((a,b)=>a.created_at.localeCompare(b.created_at));
  async function save(item){await transaction('readwrite',s=>s.put(item));}
  async function pump(){
   if(closed||busy||navigator.onLine===false)return;clearTimeout(timer);
   const item=entries.find(e=>e.status!=='sent');if(!item||item.blocked)return;busy=true;
   try{item.status='sending';await save(item);changed();const result=await send(item);item.status='sent';item.message=result.message;item.message_id=result.message_id;item.attempts=0;await save(item);changed();}
   catch(error){item.status='failed';item.error=error.message;item.attempts=(item.attempts||0)+1;item.blocked=error.retryable===false;await save(item).catch(()=>{});changed();}
   finally{busy=false;if(!closed){const first=entries.find(e=>e.status!=='sent');if(first&&!first.blocked)timer=setTimeout(pump,first.status==='failed'?Math.min(30000,1000*2**Math.min(first.attempts,5)):0);}}
  }
  const api={items(peer){return entries.filter(e=>e.peer===peer);},async enqueue(item){const value={...item,scope,status:'queued',created_at:new Date().toISOString(),client_id:crypto.randomUUID()};await save(value);entries.push(value);changed();pump();return value;},async acknowledge(messages){const ids=new Set(messages.map(m=>m.client_id).filter(Boolean)),server=new Set(messages.map(m=>m.id));const done=entries.filter(e=>e.status==='sent'&&(ids.has(e.client_id)||server.has(e.message_id)));if(!done.length)return;await transaction('readwrite',s=>done.forEach(e=>s.delete(e.client_id)));entries=entries.filter(e=>!done.includes(e));changed();},async retry(id){const e=entries.find(e=>e.client_id===id);if(e){e.blocked=false;e.status='queued';await save(e);changed();pump();}},pump,close(){closed=true;clearTimeout(timer);window.removeEventListener('online',pump);}};
  window.addEventListener('online',pump);changed();pump();return api;
 }};
})();
