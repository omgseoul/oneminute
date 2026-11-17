const {JSDOM}=require('jsdom'),fs=require('node:fs'),assert=require('node:assert/strict');
const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 const d=new JSDOM(fs.readFileSync('guest-support-settings.html','utf8'),{url:'https://fixture.test/settings',runScripts:'outside-only'}),w=d.window;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 let network=0,storage=0;
 w.fetch=()=>{network++;throw Error('Preview must not access production');};
 for(const key of ['localStorage','sessionStorage'])Object.defineProperty(w,key,{get(){storage++;throw Error('Preview must not access guest identity storage');}});
 w.createImageBitmap=()=>{throw Error('Preview must not process a real document');};
 for(const file of ['web-checkin.js','web-checkin-preview.js','web-checkin-settings.js'])w.eval(fs.readFileSync(file,'utf8'));
 const root=w.document.querySelector('.web-checkin-dialog'),form=root.querySelector('form'),field=n=>form.elements.namedItem(n),text=s=>root.querySelector(s).textContent;
 const step=()=>root.querySelector('[data-step]:not([hidden])').dataset.step;
 const submit=async(values={})=>{for(const [k,v]of Object.entries(values))field(k).value=v;form.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();};
 const restart=async()=>{root.querySelector('.wc-retry').click();await tick();assert.equal(step(),'reference');assert(!field('reference').disabled);assert(text('.wc-reference-note').startsWith('3회 남음'));assert.equal(field('reference').value,'');assert.equal(text('.wc-code'),'');};
 const dates=()=>{const info=text('.wc-preview-info');return{check_in:info.match(/체크인: (\d{4}-\d{2}-\d{2})/)[1],check_out:info.match(/체크아웃: (\d{4}-\d{2}-\d{2})/)[1]};};
 w.document.getElementById('webCheckinPreview').click();await tick();
 assert(root.open);assert(text('.wc-heading-note').includes('모의화면'));assert(!root.querySelector('.wc-retry').hidden);
 for(let i=0;i<3;i++){await submit({reference:'WRONG999999'});if(i<2){assert.equal(step(),'reference');assert(text('.wc-reference-note').startsWith((2-i)+'회 남음'));}}
 assert.equal(step(),'dates');await submit(dates());assert.equal(step(),'name');
 for(let i=0;i<3;i++)await submit({name:'없는사람'});
 assert(root.querySelector('.wc-next').disabled);assert(field('name').disabled);assert(text('.wc-name-note').includes('확인 제한'));assert.equal(text('.wc-code'),'');
 await restart();await submit({reference:'TEST123456'});assert.equal(step(),'dates');
 await submit({...dates(),check_out:'2099-01-01'});assert(text('.wc-date-note').startsWith('1회 남음'));
 await submit({...dates(),check_out:'2099-01-01'});assert(root.querySelector('.wc-next').disabled);await restart();
 await submit({reference:'TEST123456'});await submit(dates());assert.equal(step(),'choice');assert.equal(root.querySelectorAll('[name=choice_id]').length,10);
 root.querySelector('[value="preview-0"]').checked=true;await submit();assert(text('.wc-choice-note').startsWith('1회 남음'));
 root.querySelector('[value="preview-1"]').checked=true;await submit();assert(root.querySelector('.wc-next').disabled);await restart();
 await submit({reference:'TEST123456'});await submit(dates());root.querySelector('[value="preview-9"]').checked=true;await submit();assert.equal(text('.wc-code'),'TEST-0000');assert(text('.wc-greeting').includes('모의 정보'));await restart();
 for(const outcome of ['success','failure']){
  root.querySelector('.wc-unknown').click();await tick();assert.equal(step(),'dates');await submit(dates());await submit({name:'홍길동'});assert.equal(step(),'upload');
  root.querySelector('.wc-preview-outcome').value=outcome;const validity=form.reportValidity;form.reportValidity=()=>true;await submit();form.reportValidity=validity;
  if(outcome==='success')assert.equal(text('.wc-code'),'TEST-0000');else{assert(root.querySelector('.wc-next').disabled);assert.equal(text('.wc-code'),'');}
  await restart();
 }
 root.querySelector('.wc-staff').click();assert(root.open);assert(text('.wc-status').includes('모의화면'));assert.equal(network,0);assert.equal(storage,0);
 root.querySelector('.wc-close').click();assert(!root.open);w.close();
 console.log('PASS preview: settings entry, three reference failures → dates, name/date/choice locks, restart after failure/success, mock document outcomes, zero production calls/storage');
})().catch(e=>{console.error(e);process.exitCode=1;});
