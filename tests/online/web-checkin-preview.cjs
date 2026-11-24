const {JSDOM}=require('jsdom'),fs=require('node:fs'),assert=require('node:assert/strict');
const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 const d=new JSDOM(fs.readFileSync('guest-support-settings.html','utf8'),{url:'https://fixture.test/settings',runScripts:'outside-only'}),w=d.window;
 Object.defineProperty(w.navigator,'languages',{value:['ko-KR']});
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 w.OMG_SUPABASE={url:'https://fixture.test',publishableKey:'public'};w.AbortSignal.timeout=()=>undefined;
 const calls=[];let storage=0,remaining=3;
 w.fetch=async(_,options)=>{const b=JSON.parse(options.body);calls.push(b);assert.equal(b.access_token,'owner-fixture');let result={ok:true};
  if(b.action==='web_checkin_settings')result={...result,connected:true,enabled:true,source:'unit:name2',release_time:'15:00',probe:{}};
  else{assert.equal(b.action,'web_checkin_preview');const data=b.data;
   if(data.step==='resume'){remaining=3;result={...result,stage:'reference',reference_remaining:3,preview_day:'2026-11-17'};}
   else if(data.step==='reference'){remaining--;result={...result,stage:remaining?'reference':'fallback_dates',mode:remaining?'reference':'document',reference_remaining:remaining};}
   else if(data.step==='dates')result={...result,stage:'name',mode:'document',name_remaining:3};
   else if(data.step==='name')result={preview_diagnostics:['확정서 날짜: 불일치','<img src=x onerror=alert(1)>'],ok:false,code:'device_blocked',message:'직원과의 채팅으로 예약을 확인하여 주십시오.'};
  }return{ok:true,json:async()=>result};
 };
 for(const key of ['localStorage','sessionStorage'])Object.defineProperty(w,key,{get(){storage++;throw Error('Preview must not access guest identity storage');}});
 for(const file of ['web-checkin-i18n.js','web-checkin.js','web-checkin-preview.js','web-checkin-settings.js'])w.eval(fs.readFileSync(file,'utf8'));
 const root=w.document.querySelector('.web-checkin-dialog'),form=root.querySelector('form'),field=n=>form.elements.namedItem(n),text=s=>root.querySelector(s).textContent;
 const step=()=>root.querySelector('[data-step]:not([hidden])').dataset.step;
 const submit=async(values={})=>{for(const [k,v]of Object.entries(values))field(k).value=v;form.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();};
 await w.WebCheckinSettings.mount('owner-fixture');w.document.getElementById('webCheckinPreview').click();await tick();
 assert(root.open);assert(text('.wc-heading-note').includes('모의화면'));assert(!root.querySelector('.wc-retry').hidden);assert(text('.wc-preview-info').includes('실제 Beds24'));assert(text('.wc-preview-day').includes('2026-11-17'));assert.equal(root.querySelector('.wc-preview-outcome'),null);assert(!root.textContent.includes('홍길동'));assert(!root.textContent.includes('TEST123456'));
 const initial=calls.at(-1).data;
 for(let i=0;i<3;i++)await submit({reference:'WRONG999999'});
 assert.equal(step(),'dates');assert.equal(root.querySelector('.wc-date-note'),null);await submit({check_in:'2026-11-01',check_out:'2026-11-02'});assert.equal(step(),'name');await submit({name:'No Such Guest'});assert(root.querySelector('.wc-next').disabled);assert.equal(text('.wc-code'),'');assert(!root.querySelector('.wc-preview-diagnostics').hidden);assert(text('.wc-preview-diagnostics').includes('날짜: 불일치'));assert.equal(root.querySelector('.wc-preview-diagnostics img'),null);
 root.querySelector('.wc-retry').click();await tick();assert.equal(step(),'reference');assert(root.querySelector('.wc-preview-diagnostics').hidden);assert(!field('reference').disabled);assert(text('.wc-reference-note').startsWith('3회 남음'));assert.equal(field('reference').value,'');const retry=calls.at(-1).data;assert.notEqual(retry.verification_token,initial.verification_token);assert.notEqual(retry.device_id,initial.device_id);assert.equal(storage,0);
 root.querySelector('.wc-close').click();assert(!root.open);w.close();
 console.log('PASS real preview adapter: authenticated API, no fabricated data, date continuation, isolated retry IDs, zero guest storage');
})().catch(e=>{console.error(e);process.exitCode=1;});
