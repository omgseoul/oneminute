/* Account-scoped, bounded disk cache. Only explicit viewer opens download originals. */
(function(){
 const NAME='oms-chat-media-v1',MAX=64*1024*1024;let database;
 const scope=s=>s.sessionId&&JSON.stringify([s.sessionId,s.sessionKind,s.ownerId||'',s.employeeId||'']);
 async function db(){if(!window.indexedDB)return null;if(!database)database=new Promise((resolve,reject)=>{const r=indexedDB.open(NAME,1);r.onupgradeneeded=()=>r.result.createObjectStore('media',{keyPath:'key'});r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});return database;}
 async function transaction(mode,task){try{const d=await db();if(!d)return null;return await new Promise((resolve,reject)=>{const t=d.transaction('media',mode),r=task(t.objectStore('media'));let answer;r.onsuccess=()=>answer=r.result;t.oncomplete=()=>resolve(answer);t.onerror=t.onabort=()=>reject(t.error);});}catch{return null;}}
 const active=s=>!window.omgSession?.get||scope(window.omgSession.get()||{})===scope(s);
 async function get(s,id){const a=scope(s);if(!a||!active(s))return null;const item=await transaction('readonly',store=>store.get(a+':'+id));if(active(s)&&item&&Date.now()-item.at<7*86400000)return item.blob;return null;}
 async function put(s,id,blob){const a=scope(s);if(!a||!active(s)||blob.size>20*1024*1024)return;await transaction('readwrite',store=>store.put({key:a+':'+id,scope:a,blob,at:Date.now()}));const rows=await transaction('readonly',store=>store.getAll())||[];let total=0;for(const row of rows.sort((x,y)=>y.at-x.at)){total+=row.blob.size;if(row.scope!==a||total>MAX||Date.now()-row.at>7*86400000)await transaction('readwrite',store=>store.delete(row.key));}}
 async function preview(data){if(!/^data:image\/jpeg;base64,/.test(data||''))return null;const image=new Image();await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;image.src=data;});const scale=Math.min(1,320/Math.max(image.naturalWidth,image.naturalHeight)),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(image.naturalWidth*scale));canvas.height=Math.max(1,Math.round(image.naturalHeight*scale));canvas.getContext('2d').drawImage(image,0,0,canvas.width,canvas.height);for(const quality of [.65,.45,.25]){const result=canvas.toDataURL('image/jpeg',quality);if(result.length<87000)return result;}return null;}
 let lastScope=scope(window.omgSession?.get?.()||{});
 addEventListener('omg:session-changed',()=>{const next=scope(window.omgSession?.get?.()||{});if(next!==lastScope)transaction('readwrite',store=>store.clear());lastScope=next;});
 window.OMSChatMediaCache={get,put,preview};
})();
