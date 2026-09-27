const {JSDOM}=require('jsdom'),fs=require('node:fs'),assert=require('node:assert/strict');
const read=f=>fs.readFileSync(f,'utf8'),tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 for(let count=1;count<=10;count++){
  const d=new JSDOM(read('guest.html'),{url:'https://example.test/guest.html?p=test',runScripts:'outside-only'}),w=d.window;
  w.GuestSupport={esc:s=>s,message:()=>{},call:async()=>({name:'Hotel',chat_enabled:true,items:Array.from({length:count-1},(_,i)=>({title:'Item '+i,icon:i===0?'13':null}))})};
  w.HTMLDialogElement.prototype.showModal=function(){this.open=true};w.HTMLDialogElement.prototype.close=function(){this.open=false};
  w.eval(read('guest-icons.js'));w.eval(read('guest-portal.js'));await tick();
  const buttons=[...w.document.querySelectorAll('.portal-menu')],rows=Math.max(3,Math.ceil(count/2));
  assert.equal(buttons.length,count);assert.ok(buttons.at(-1).classList.contains('chat-menu'));
  assert.equal(buttons.filter(b=>b.classList.contains('full')).length,Math.min(count,rows*2-count));
  assert.equal(w.document.querySelector('.portal-menus').style.getPropertyValue('--rows'),String(rows));
  if(count>2)assert.equal(buttons[1].querySelector('svg'),null);
  buttons.at(-1).click();const room=w.document.getElementById('roomNumber'),unknown=w.document.getElementById('roomUnknown');assert.ok(room.required);unknown.click();assert.ok(room.disabled&&!room.required);unknown.click();assert.ok(!room.disabled&&room.required);
  assert.equal(w.GuestIcons.items.length,50);assert.equal(w.GuestIcons.items[12].label,'휴지');assert.equal(w.GuestIcons.items[48].label,'비상구');d.window.close();
 }
 const d=new JSDOM(read('guest-support-settings.html'),{url:'https://example.test/guest-support-settings.html',runScripts:'outside-only'}),w=d.window;let saved;
 w.omgSession={require:async()=>({sessionKind:'owner',accessToken:'test'})};w.GuestSupport={esc:s=>s,message:()=>{},call:async(a,data)=>{if(a==='save_settings'){saved=data;return{};}return{config:{enabled:true,chat_enabled:true,slug:'test',items:[{title:'Door',asset_id:'asset',icon:'01'}]},assets:[{id:'asset',mime:'image/jpeg'}]};}};
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true};w.HTMLDialogElement.prototype.close=function(){this.open=false};
 w.eval(read('guest-icons.js'));w.eval(read('guest-support-settings.js'));await tick();
 assert.equal(w.document.querySelectorAll('.icon-option').length,50);assert.equal(w.document.getElementById('enabledLabel').textContent,'활성화');
 w.document.querySelector('.select-icon').click();w.document.querySelector('[data-icon="13"]').click();
 w.document.getElementById('settings').dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.equal(saved.items[0].icon,'13');
 assert.equal(w.document.querySelector('.attach-file').textContent,'변경');
 for(let i=0;i<8;i++)w.document.getElementById('add').click();assert.equal(w.document.querySelectorAll('#items .item-editor').length,9);assert.ok(w.document.getElementById('add').disabled);
 w.close();console.log('PASS menu layout rules 1–10, icon selection, save payload, room unknown, and nine-item limit');
})().catch(e=>{console.error(e);process.exitCode=1});
