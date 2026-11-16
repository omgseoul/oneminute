const fs=require('fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
(async()=>{const browser=await chromium.launch({headless:true});try{
 const page=await browser.newPage();await page.route('**/*',r=>r.fulfill({contentType:'text/html',body:'<!doctype html><body></body>'}));await page.goto('https://oms.test/media');
 await page.addScriptTag({content:fs.readFileSync('chat-media-cache.js','utf8')});await page.addScriptTag({content:fs.readFileSync('staff-chat-client.js','utf8')});
 const result=await page.evaluate(async()=>{
  let current={sessionId:'login-a',sessionKind:'owner',ownerId:'a',accessToken:'fixture'},calls=0;window.omgSession={get:()=>current};
  const canvas=document.createElement('canvas');canvas.width=1000;canvas.height=700;canvas.getContext('2d').fillRect(0,0,1000,700);const data=canvas.toDataURL('image/jpeg'),preview=await OMSChatMediaCache.preview(data);
  StaffChat.call=async(_,action)=>{calls++;return action==='download_info'?{byte_length:3,part_size:1048576,mime_type:'image/jpeg'}:{byte_length:3,part_index:0,mime_type:'image/jpeg',chunk:'/9j/'};};
  const original=current;const one=await StaffChat.download(current,'employee:a','photo');await StaffChat.download(current,'employee:a','photo');const cachedCalls=calls;
  current={...current,sessionId:'login-b',ownerId:'b'};const assertEmpty=await OMSChatMediaCache.get(current,'photo');await OMSChatMediaCache.put(original,'late',one);const late=await OMSChatMediaCache.get(current,'late');await StaffChat.download(current,'employee:a','photo');
  const afterSwitch=calls;dispatchEvent(new Event('omg:session-changed'));await new Promise(r=>setTimeout(r,20));const afterLogout=await OMSChatMediaCache.get(current,'photo');
  const image=new Image();await new Promise(r=>{image.onload=r;image.src=preview;});
  return{cachedCalls,afterSwitch,isolated:assertEmpty===null&&late===null&&afterLogout===null,previewWidth:image.width,previewBytes:preview.length};
 });
 assert.equal(result.cachedCalls,2,'one info + one part, repeat open uses disk cache');assert.equal(result.afterSwitch,4,'different account downloads independently');assert(result.isolated);assert.equal(result.previewWidth,320);assert(result.previewBytes<87500);
 console.log('PASS thumbnail dimensions/size, original reuse, account isolation, late-write rejection and logout clearing');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
