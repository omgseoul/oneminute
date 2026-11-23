const {chromium}=require('playwright'),fs=require('fs'),assert=require('node:assert/strict');
(async()=>{const browser=await chromium.launch({headless:true});try{for(const width of [320,360,412]){
 const page=await browser.newPage({viewport:{width,height:850},deviceScaleFactor:2}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{
  window.omgSession={require:async()=>({sessionKind:'owner',propertyId:'nest',accessToken:'fixture'})};window.OMG_SUPABASE={url:'https://fixture.test',publishableKey:'public'};
  window.saved=[];const rows={nest:[],omg:[]};
  window.fetch=async(u,o)=>{const {action,data}=JSON.parse(o.body);if(action==='auto_message_save'){window.saved.push(structuredClone(data));const existing=rows[data.property_id].findIndex(r=>r.id===data.id),rule={...data,revision:(data.revision||0)+1};if(existing<0)rows[data.property_id].push(rule);else rows[data.property_id][existing]=rule;}
   return {ok:true,json:async()=>({ok:true,property_id:data.property_id,branches:[{id:'nest',name:'Seoulnest'},{id:'omg',name:'Omghouse'}],rules:structuredClone(rows[data.property_id]),logs:[]})};};
 });
 const keep=new Set(['guest-auto-messages.js','property-selector.js']);const html=fs.readFileSync('guest-auto-messages.html','utf8').replace(/<script src="([^"]+)"[^>]*><\/script>/g,(all,url)=>keep.has(url.split('?')[0])?all:'');
 await page.route('**/*',r=>{const file=new URL(r.request().url()).pathname.slice(1);if(file==='guest-auto-messages.html')return r.fulfill({body:html,contentType:'text/html'});if(!file.includes('..')&&fs.existsSync(file)&&fs.statSync(file).isFile())return r.fulfill({path:file});return r.fulfill({status:204,body:''});});
 await page.goto('https://omgworks24.com/guest-auto-messages.html');await page.waitForFunction(()=>!document.getElementById('addAutoMessage').disabled);
 await page.locator('#autoProperty button').click();assert.equal(await page.locator('#autoProperty input[type=checkbox]').count(),0);assert.equal(await page.locator('#autoProperty input[type=radio]').count(),2);assert(!await page.locator('#autoProperty').textContent().then(x=>x.includes('All')));await page.locator('#autoProperty button').click();
 await page.locator('#addAutoMessage').click();const form=page.locator('.auto-editor form');await form.locator('textarea').fill('안녕하세요 ');await form.locator('[data-variable="이름"]').click();await form.locator('[data-variable="비밀번호"]').click();assert.equal(await form.locator('textarea').inputValue(),'안녕하세요 {{이름}}{{비밀번호}}');
 await form.locator('[name=trigger]').selectOption('booking_after');await form.locator('[name=days]').fill('3');await form.locator('[data-step="1"]').click();assert.equal(await form.locator('[name=days]').inputValue(),'4');await form.locator('[data-step="-1"]').click();assert.equal(await form.locator('[name=days]').inputValue(),'3');
 await form.locator('.auto-add-language').click();await page.locator('#autoLanguage').selectOption('ja');await page.locator('#autoLanguageForm button.primary').click();await form.locator('textarea').fill('こんにちは {{이름}}');await form.locator('[data-language=common]').click();assert.equal(await form.locator('textarea').inputValue(),'안녕하세요 {{이름}}{{비밀번호}}');
 assert.equal(await form.locator('[name=days]').inputValue(),'3','adding language preserves timing');
 await form.locator('[name=trigger]').selectOption('checkin_before');await form.locator('[name=send_time]').fill('15:30');
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'page fits viewport');assert(await form.locator('.auto-timing').evaluate(e=>e.scrollWidth<=e.clientWidth),'timing fits');assert(await form.locator('.auto-compose').evaluate(e=>e.scrollWidth<=e.clientWidth),'composer fits');
 await page.screenshot({path:'/tmp/auto-message-editor-'+width+'.png',fullPage:true});
 await form.locator('.auto-submit').click();assert(await page.locator('#autoTitleDialog').isVisible());assert.equal(await page.evaluate(()=>saved.length),0,'nothing saved before title');await page.locator('#autoTitle').fill('체크인 안내');await page.locator('#autoTitleForm button.primary').click();await page.waitForFunction(()=>saved.length===1&&!document.getElementById('autoTitleDialog').open);
 const saved=await page.evaluate(()=>saved[0]);assert.equal(saved.property_id,'nest');assert.equal(saved.title,'체크인 안내');assert.equal(saved.send_time,'15:30');assert.equal(saved.messages.ja,'こんにちは {{이름}}');assert.equal(await page.locator('.auto-card[open]').count(),0,'saved items collapsed');
 await page.screenshot({path:'/tmp/auto-message-list-'+width+'.png',fullPage:true});
 await page.locator('#autoProperty button').click();await page.locator('#autoProperty input[value=omg]').check();await page.waitForSelector('.auto-empty');assert.equal(await page.locator('.auto-card').count(),0,'other property has separate rules');
 assert.deepEqual(errors,[]);await page.close();
 }console.log('Auto message UI: 320/360/412px, single branch/no All, add button, insertion, day stepper, languages, title-after-content and isolated branch list passed');}finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1)});
