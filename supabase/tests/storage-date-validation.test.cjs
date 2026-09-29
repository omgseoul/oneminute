const {test}=require('node:test'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom'),fs=require('node:fs'),path=require('node:path');
test('invalid date changes show branded popup and never request a deletion preview',async()=>{
 const d=new JSDOM('<div id="host"></div>',{runScripts:'outside-only'}),w=d.window,calls=[];
 w.omgSupabase={rpc:async(name,args)=>{calls.push(args.p_action);return {data:{ok:true,properties:[{property_id:'p',property_name:'Test',chat_count:0,message_count:0,chat_photo_count:0,attendance_count:0}],pending_jobs:[]}}}};
 w.eval(fs.readFileSync(path.join(__dirname,'../../platform-storage.js'),'utf8'));w.PropertyDataManagement.mount({host:w.document.querySelector('#host'),accessToken:'test'});await new Promise(r=>setTimeout(r,0));
 const start=w.document.querySelector('.storage-start'),end=w.document.querySelector('.storage-end'),period=w.document.querySelector('.storage-months');period.value='custom';period.dispatchEvent(new w.Event('change'));
 start.value='2026-09-20';end.value='2026-09-01';end.dispatchEvent(new w.Event('change'));assert.equal(end.value,'');assert.match(w.document.querySelector('[role=dialog]').textContent,/종료일은 시작일보다 앞으로 갈 수 없습니다/);w.document.querySelector('.storage-modal-confirm').click();await new Promise(r=>setTimeout(r,0));
 end.value='2026-09-19';w.document.querySelector('.storage-preview').click();assert(w.document.querySelector('[role=dialog]'));assert.deepEqual(calls,['usage']);w.document.querySelector('.storage-modal-confirm').click();await new Promise(r=>setTimeout(r,0));
 end.value='2026-09-20';end.dispatchEvent(new w.Event('change'));assert(!w.document.querySelector('[role=dialog]'));start.value='2026-09-21';start.dispatchEvent(new w.Event('change'));assert.equal(start.value,'');assert(w.document.querySelector('[role=dialog]'));d.window.close();
});
