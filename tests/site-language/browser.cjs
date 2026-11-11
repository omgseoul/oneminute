const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const files=['index.html','feature-staff.html','feature-tasks.html','feature-cleaning.html','feature-messenger.html'];
(async()=>{const browser=await chromium.launch({headless:true});try{
 const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',route=>{const u=new URL(route.request().url()),file=u.pathname.slice(1)||'index.html';if(u.origin==='https://omgworks24.com'&&!file.includes('..')&&fs.existsSync(file)&&fs.statSync(file).isFile())return route.fulfill({path:file});return route.fulfill({status:204,body:''});});
 for(const width of [320,390,768,1024,1440])for(const file of files){
  await page.setViewportSize({width,height:900});await page.goto('https://omgworks24.com/'+file+'?lang=en');await page.waitForFunction(()=>document.documentElement.lang==='en'&&document.querySelector('[data-site-language]').value==='en');
  const problems=await page.evaluate(()=>{
   const bad=[],width=document.documentElement.clientWidth;
   if(document.documentElement.scrollWidth>width+1)bad.push('page overflow '+document.documentElement.scrollWidth+' > '+width);
   for(const el of document.querySelectorAll('h1,h2,h3,.tagline,.work-friction p,.button,.feature-nav a,.site-language-control,.photo-actions button,.urgent-compose button')){
    const b=el.getBoundingClientRect();if(!b.width||!b.height)continue;
    if(b.left< -1||b.right>width+1||el.scrollWidth>el.clientWidth+2)bad.push(el.className+' '+el.textContent.trim()+': overflow');
   }
   for(const el of document.querySelectorAll("body *")){if(!el.getBoundingClientRect().width)continue;for(const pseudo of ["::before","::after"]){if(/[가-힣]/.test(getComputedStyle(el,pseudo).content))bad.push("Untranslated generated copy: "+el.className);}}
   return bad;
  });assert.deepEqual(problems,[],width+' '+file);
  if(width===390||width===1440)await page.screenshot({path:'/tmp/oms-site-'+file.replace('.html','')+'-'+width+'.png',fullPage:true});
 }
 await page.setViewportSize({width:390,height:850});await page.goto('https://omgworks24.com/index.html');await page.selectOption('[data-site-language]','en');await page.locator('.feature-card').first().click();await page.waitForURL('**/feature-staff.html?*');assert.equal(await page.locator('html').getAttribute('lang'),'en');
 await page.locator('[data-sign-clear]').click();await page.locator('[data-sign-complete]').click();await page.getByText('Please add your signature.',{exact:true}).waitFor();
 await page.selectOption('[data-site-language]','ko');await page.getByText('서명을 입력해주세요.',{exact:true}).waitFor();await page.reload();assert.equal(await page.locator('html').getAttribute('lang'),'ko');
 await page.goto('https://omgworks24.com/feature-cleaning.html?lang=en');await page.locator('[data-photo-omit]').click();await page.getByText('Photo missing',{exact:true}).waitFor();assert(await page.locator('[data-report-submit]').isDisabled());await page.locator('[data-photo-omit]').click();await page.locator('[data-report-submit]').click();await page.getByText('Report submitted',{exact:true}).waitFor();
 await page.locator('.report-photo').click();await page.locator('#zoom-demo').click();await page.getByRole('button',{name:'Zoom out of photo',exact:true}).waitFor();await page.locator('#close-photo').click();
 await page.goto('https://omgworks24.com/feature-messenger.html?lang=en');await page.locator('[data-urgent-send]').click();await page.locator('[data-urgent-ack]').click();await page.getByText('Acknowledged → Alerts stop',{exact:true}).waitFor();
 await page.goto('https://omgworks24.com/feature-tasks.html?lang=en');await page.locator('.demo-complete').click();await page.getByText('✓ Task complete',{exact:true}).waitFor();assert.equal(await page.locator('.weekdays span').first().textContent(),'Mon');assert.equal(await page.locator('.weekdays span').last().textContent(),'Sun');
 assert.deepEqual(errors,[]);console.log('PASS English responsive layouts on 5 pages at 320/390/768/1024/1440px; language persistence, navigation and interactive demos in both languages');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
