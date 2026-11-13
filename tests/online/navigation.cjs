const {chromium}=require('playwright'),fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const browser=await chromium.launch({...(process.env.OMS_CHROMIUM_PATH?{executablePath:process.env.OMS_CHROMIUM_PATH}:{}),headless:true,args:['--no-sandbox']}),page=await browser.newPage({viewport:{width:360,height:780}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',r=>{const f=new URL(r.request().url()).pathname.slice(1);if(['online.html','online.css','online.js','top-layout.css','property-selector.js','select-picker.js'].includes(f))return r.fulfill({body:fs.readFileSync(f),contentType:f.endsWith('.css')?'text/css':f.endsWith('.js')?'text/javascript':'text/html'});return r.fulfill({body:'',contentType:'text/javascript'});});
 await page.addInitScript(()=>{
  window.omgSession={require:async()=>({sessionKind:'owner',accessToken:'fixture',propertyId:'home'})};window.OMG_SUPABASE={url:'https://fixture.test',publishableKey:'test'};
  window.fetch=async(u,o)=>{const {action,data}=JSON.parse(o.body),p=data.property_id||'home',names={home:'One Minute',other:'OMG House'};let v={ok:true};
   if(action==='settings')v={ok:true,property_id:p,property_name:names[p],branches:Object.entries(names).map(([id,name])=>({id,name})),properties:[{id:1,name:'1 One Minute'}],beds_property_id:1,connected:true,ai_mode:'off'};
   if(action==='bookings'||action==='sync_bookings')v={ok:true,bookings:[{id:123,guest_name:'19 Myung Paik',channel:'Booking.com',arrival:'2026-11-12',departure:'2026-11-13',status:'confirmed',data:{numAdult:1}},{id:124,guest_name:'20Ana Martínez de Long Name',channel:'Airbnb',arrival:'2026-11-12',departure:'2026-11-18',status:'new',data:{numAdult:2}}]};
   if(action==='inbox'||action==='sync_messages'&&!data.booking_id)v={ok:true,threads:[]};if(action==='logs')v={ok:true,logs:[]};if(action==='thread'||action==='sync_messages'&&data.booking_id)v={ok:true,booking:{guest_name:'Guest'},messages:[],outbox:[]};return {ok:true,json:async()=>v};
  };
 });
 await page.goto('https://omgworks24.com/online.html');await page.locator('#propertyName button').waitFor();
 await page.locator('.menu-card[href="#search"]').click();await page.locator('.booking-item').first().waitFor();
 for(const width of [320,360,412]){
  await page.setViewportSize({width,height:780});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  const box=await page.locator('.booking-item summary').first().evaluate(e=>({h:e.getBoundingClientRect().height,tops:[...e.children].map(c=>Math.round(c.getBoundingClientRect().top)),scroll:e.scrollWidth,width:e.clientWidth}));assert(box.h<=52,'one-row booking summary');assert(box.scroll<=box.width);assert(Math.max(...box.tops)-Math.min(...box.tops)<7,'fields align on one line');
 }
 await page.setViewportSize({width:360,height:780});await page.screenshot({path:'/tmp/online-reservations-compact.png'});
 await page.locator('.booking-item summary').first().click();await page.locator('.booking-item[open] .text-link').click();await page.waitForFunction(()=>document.body.dataset.view==='thread');
 await page.goBack();await page.waitForFunction(()=>document.body.dataset.view==='search');
 await page.locator('#onlineBack').click();await page.waitForFunction(()=>document.body.dataset.view==='menu');
 await page.locator('.menu-card[href="#today"]').click();await page.waitForFunction(()=>document.body.dataset.view==='today');await page.goBack();await page.waitForFunction(()=>document.body.dataset.view==='menu');
 await page.locator('#propertyName button').click();await page.locator('#propertyName input[data-value="other"]').check();await page.locator('#propertyName button').click();assert.equal(await page.locator('#propertyName button').innerText(),'All');
 await page.locator('.menu-card[href="#settings"]').click();await page.waitForFunction(()=>document.body.dataset.view==='settings');assert.equal(await page.locator('#propertyName input[type=radio]').count(),2);assert.equal(await page.locator('#propertyName input[type=checkbox]').count(),0);
 await page.locator('#propertyName button').click();await page.screenshot({path:'/tmp/online-property-single.png'});await page.locator('#propertyName input[value="other"]').check();await page.waitForFunction(()=>document.querySelector('#webhookProperty').textContent==='OMG House');assert(await page.locator('#bedsPropertyPickerButton').isDisabled());assert(!(await page.locator('#bedsProperty').isVisible()));
 await page.locator('#onlineBack').click();await page.waitForFunction(()=>document.body.dataset.view==='menu');assert.equal(await page.locator('#propertyName button').innerText(),'All');await page.locator('#propertyName button').click();await page.screenshot({path:'/tmp/online-property-multi.png'});
 await page.goto('https://omgworks24.com/app.html');
 await page.goto('https://omgworks24.com/online.html#thread/123?property=other&from=search');await page.waitForFunction(()=>document.body.dataset.view==='thread');await page.goBack();await page.waitForFunction(()=>document.body.dataset.view==='search');await page.goBack();await page.waitForFunction(()=>document.body.dataset.view==='menu');assert.deepEqual(errors,[]);
 await browser.close();console.log('Chromium: one-line reservations at 320/360/412px, expansion, native/browser and header back, custom single/multi controls and direct-link parent history passed.');
})().catch(e=>{console.error(e);process.exit(1)});
