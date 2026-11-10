const {chromium}=require('playwright'),fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
(async()=>{const browser=await chromium.launch({headless:true});try{for(const width of [320,360,412,900]){
 const page=await browser.newPage({viewport:{width,height:740}});
 const html=fs.readFileSync('messages.html','utf8').replace(/<script[\s\S]*?<\/script>/g,'').replace(/<link[^>]*>/g,'').replace(/omg-booting/g,'');
 await page.route('https://central.test/**',r=>r.request().url().endsWith('.webp')?r.fulfill({path:path.resolve('oms-dog-normal-plain.webp')}):r.fulfill({contentType:'text/html',body:html}));await page.goto('https://central.test/messages.html');
 for(const file of ['dialog-cards.css','central-notices.css'])await page.addStyleTag({path:file});for(const file of ['dialog-cards.js','attendance-warning-response.js'])await page.addScriptTag({path:file});
 for(const type of ['attendance_warning','announcement']){
  await page.evaluate(type=>{const $=id=>document.getElementById(id);OMSDialogs.present({message_type:type,require_signature:true,require_understanding:true});$('detailMeta').innerHTML='<span class="detail-avatar">변</span><span class="detail-who"><b>변지훈 · One Minute</b><small>2026. 11. 10.</small></span>';$('detailBody').textContent=type==='announcement'?'오늘 객실 정비 후 비품 수량을 확인해주세요. 변경된 업무 내용을 확인하고 체크해주세요.':'예정 출근시간과 차이가 있습니다. 관리자와 협의한 내용인지 확인해주세요.';$('detail').hidden=false;$('ackStatus').hidden=true;$('announcementConfirm').hidden=type!=='announcement';$('ack').textContent='완료';$('close').hidden=true;
   let host=$('testResponse');if(!host){host=document.createElement('div');host.id='testResponse';$('detailBody').after(host);}host.hidden=type!=='attendance_warning';if(type==='attendance_warning')OMSAttendanceResponse.mount(host,$('ack'));
  },type);
  if(type==='attendance_warning'){await page.getByRole('button',{name:'아니오',exact:true}).click();await page.locator('.awr-reason textarea').fill('체크인이 늦어진 손님 응대로 야근했습니다.');}
  const card=await page.locator('#detail .sheet').boundingBox(),button=await page.locator('#ack').boundingBox();assert(card.x>=0&&card.x+card.width<=width+1);assert(card.y>0&&card.y+card.height<740);assert(button.y+button.height<740);assert.equal(await page.locator('#detail .sheet-top').evaluate(e=>getComputedStyle(e).backgroundColor),type==='announcement'?'rgb(220, 239, 227)':'rgb(36, 103, 189)');
  if(width===360)await page.screenshot({path:'/tmp/oms-central-'+type+'.png'});
 }await page.close();}
 console.log('PASS central attendance/green notice cards at 320/360/412/900px, reason expansion and visible completion button');}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
