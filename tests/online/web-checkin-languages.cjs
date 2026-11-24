const assert=require('node:assert/strict'),fs=require('node:fs'),{JSDOM}=require('jsdom'),{chromium}=require('playwright');
const tick=()=>new Promise(resolve=>setImmediate(resolve)),read=f=>fs.readFileSync(f,'utf8');
function fixture(){
 window.calls=[];window.staffCalls=0;window.failUpload=false;window.OMG_SUPABASE={url:'https://fixture.test',publishableKey:'fixture'};
 window.fetch=async(_,options)=>{const body=JSON.parse(options.body),d=body.data;calls.push(body);let v;
 if(d.step==='resume')v={ok:true,stage:'reference',mode:'reference',reference_remaining:3};
 else if(d.step==='reference')v={ok:true,stage:'reference',mode:'reference',reference_remaining:2,message:'예약번호가 확인되지 않습니다. 다시 확인해주세요.'};
 else if(d.step==='unknown')v={ok:true,stage:'fallback_dates',mode:'document'};
 else if(d.step==='dates')v={ok:true,stage:'name',mode:'document',name_remaining:3};
 else if(d.step==='name')v={ok:true,stage:'upload',mode:'document'};
 else if(d.step==='upload')v=failUpload?{ok:false,code:'staff_required',message:'직원과의 채팅으로 예약을 확인하여 주십시오.',preview_diagnostics:['확정서 체크인·체크아웃 날짜: 불일치 또는 판독되지 않음','확정서 이름: 일치율 89.9% · 90% 미만 또는 판독되지 않음']}:{ok:true,stage:'complete',property:'OMG House',room:'201',access_code:'TEST1234',greeting:'안녕하세요. 예약이 확인되었습니다. 편안한 숙박 되세요!'};
 return {ok:true,json:async()=>v};
 };
}
(async()=>{
 const w=new JSDOM('<html><body></body></html>',{url:'https://fixture.test',runScripts:'outside-only'}).window;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};w.AbortSignal.timeout=()=>undefined;Object.defineProperty(w.navigator,'languages',{value:['fr-CA','en']});w.eval('('+fixture.toString()+')()');for(const path of ['web-checkin-i18n.js','web-checkin.js'])w.eval(read(path));
 const i=w.WebCheckinI18n,root=w.document.querySelector('.web-checkin-dialog'),form=root.querySelector('form'),select=root.querySelector('.wc-language select');
 assert.equal(i.locales.length,9);assert.equal(i.resolve(['zh-Hant-HK']),'zh-TW');assert.equal(i.resolve(['zh-SG']),'zh-CN');assert.equal(i.resolve(['de-AT']),'de');assert.equal(i.resolve(['xx','ja-JP']),'ja');assert.equal(i.resolve(['xx']),'en');
 for(const [locale]of i.locales){assert(i.t(locale,'staff'));const message=i.translate(locale,'확정서 이름: 일치율 89.9% · 90% 미만 또는 판독되지 않음');assert(message.includes('89.9'));assert(!message.includes('{'));assert(i.translate(locale,'웹체크인은 체크인 당일 15:00부터 다음 날 11:00까지 가능합니다.').includes('15:00'));if(locale!=='ko')assert(!/[가-힣]/.test(message));}
 await w.WebCheckin.open('fixture',()=>w.staffCalls++);assert.equal(root.lang,'fr');assert.equal(select.value,'fr');assert.equal(root.querySelector('h2').textContent,i.t('fr','title'));
 const change=locale=>{select.value=locale;select.dispatchEvent(new w.Event('change'));};
 form.elements.reference.value='KEEP123';const initial=w.calls.length;change('de');assert.equal(form.elements.reference.value,'KEEP123');assert.equal(w.calls.length,initial);assert.equal(w.localStorage.getItem('wc-language'),'de');assert.equal(root.querySelector('.wc-staff span').textContent,'Mit dem Personal chatten');assert(root.querySelector('.wc-staff svg'));
 form.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.equal(root.querySelector('.wc-status').textContent,i.t('de','referenceInvalid'));assert(root.querySelector('.wc-reference-note').textContent.includes('2'));
 for(const [locale]of i.locales){change(locale);assert.equal(form.elements.reference.value,'KEEP123');assert.equal(root.querySelector('.wc-status').textContent,i.t(locale,'referenceInvalid'));assert(root.querySelector('.wc-reference-note').textContent.includes('2'));assert.equal(w.calls.length,initial+1);}
 change('en');root.querySelector('.wc-staff').click();assert.equal(w.staffCalls,1);assert(!root.open);await w.WebCheckin.open('fixture',()=>{});assert.equal(root.lang,'en','remembered choice beats device locale');root.querySelector('.wc-close').click();
 // Preview language selection must not touch guest storage, reset attempts or navigate to staff.
 for(const key of ['localStorage','sessionStorage'])Object.defineProperty(w,key,{get(){throw Error('preview storage access');}});
 await w.WebCheckin.open('',null,()=>({propertyName:'OMG House',request:async()=>{const e=Error('직원과의 채팅으로 예약을 확인하여 주십시오.');e.code='staff_required';e.previewDiagnostics=['확정서 이름: 일치율 89.9% · 90% 미만 또는 판독되지 않음'];throw e;}}));change('fr');assert(root.querySelector('.wc-preview-diagnostics').textContent.includes('89.9'));assert(!/[가-힣]/.test(root.querySelector('.wc-preview-diagnostics').textContent));assert.equal(root.querySelector('.wc-next').textContent,i.t('fr','ended'));root.querySelector('.wc-staff').click();assert.equal(root.querySelector('.wc-status').textContent,i.t('fr','previewChat'));w.close();
 console.log('Languages DOM: nine locales, device/default resolution, persistence, translated errors/diagnostics, state and attempt preservation, staff action and preview isolation passed');
 if(process.env.OMS_DOM_ONLY==='1')return;
 const browser=await chromium.launch();try{
 for(const width of [320,390,412]){
 const page=await browser.newPage({locale:'fr-FR',viewport:{width,height:850}}),errors=[];page.on('pageerror',e=>errors.push(e.message));await page.route('https://fixture.test/**',r=>r.fulfill({contentType:'text/html',body:'<html><body style="font-family:Arial"></body></html>'}));await page.goto('https://fixture.test');await page.addStyleTag({path:'web-checkin.css'});await page.evaluate(fixture);for(const path of ['web-checkin-i18n.js','web-checkin.js'])await page.addScriptTag({path});await page.evaluate(()=>WebCheckin.open('fixture',()=>staffCalls++));
 const language=page.locator('.wc-language select');assert.equal(await language.inputValue(),'fr');await page.locator('[name=reference]').fill('KEEP123');const before=await page.evaluate(()=>calls.length);
 for(const locale of ['ko','en','ja','zh-CN','zh-TW','vi','th','fr','de']){await language.selectOption(locale);assert.equal(await page.locator('[name=reference]').inputValue(),'KEEP123');assert.equal(await page.evaluate(()=>calls.length),before);assert(await page.locator('.web-checkin-dialog').evaluate(e=>e.scrollWidth<=e.clientWidth));assert(await language.evaluate(e=>e.getBoundingClientRect().right<=innerWidth));}
 await page.screenshot({path:'/tmp/online-checkin-language-header-'+width+'.png'});await page.locator('.wc-unknown').click();await page.locator('[name=check_in]').fill('2026-11-24');await page.locator('[name=check_out]').fill('2026-11-28');await language.selectOption('fr');assert.equal(await page.locator('[name=check_in]').inputValue(),'2026-11-24');await page.locator('.wc-next').click();await page.locator('[name=name]').fill('MARIA FERNANDEZ');await page.locator('.wc-next').click();
 const encoded=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=80;c.height=80;return c.toDataURL('image/png').split(',')[1];});const file={name:'name.png',mimeType:'image/png',buffer:Buffer.from(encoded,'base64')};await page.locator('[name=document]').setInputFiles([file,{...file,name:'dates.png'}]);const uploadCalls=await page.evaluate(()=>calls.length);await language.selectOption('de');assert.equal(await page.locator('[name=document]').evaluate(e=>e.files.length),2);assert.equal(await page.evaluate(()=>calls.length),uploadCalls);assert(await page.locator('.wc-file-name').textContent().then(t=>t.includes('name.png')&&t.includes('dates.png')));assert(await page.locator('.web-checkin-dialog').evaluate(e=>e.scrollWidth<=e.clientWidth));await page.screenshot({path:'/tmp/online-checkin-language-upload-'+width+'.png'});
 await page.locator('.wc-next').click();await page.locator('.wc-code').filter({hasText:'TEST1234'}).waitFor();await language.selectOption('fr');assert.equal(await page.locator('.wc-code').textContent(),'TEST1234');assert.equal(await page.locator('.wc-result h3').textContent(),'OMG House');assert.equal(await page.locator('.wc-room').textContent(),'201');assert.equal(await page.locator('.wc-greeting').textContent(),await page.evaluate(()=>WebCheckinI18n.t('fr','resultGreeting')));await page.locator('.wc-staff').click();assert.equal(await page.evaluate(()=>staffCalls),1);assert.deepEqual(errors,[]);await page.close();
 }
 }finally{await browser.close();}
 console.log('Languages browser: 320/390/412px, all nine selectors, retained dates/photos, result data and staff navigation passed');
})().catch(e=>{console.error(e);process.exit(1)});
