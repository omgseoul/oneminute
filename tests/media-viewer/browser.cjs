const {chromium}=require('playwright'),fs=require('fs'),path=require('path'),http=require('http'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../..'),peer='employee:11111111-1111-4111-8111-111111111111';
const fixture=`
window.GuestSupport={esc:s=>String(s??'')};window.omgSession={require:async()=>({accessToken:'fixture'})};
window.OMSChatLive={connect:()=>({connected:true,close(){}})};
window.partWaiters=[];window.partCalls=0;
const rows=[{id:'photo',body:'객실 사진',photo:'/feature-room-demo.webp',attachment_type:'image/jpeg'},{id:'video',body:'동영상',attachment_type:'video/mp4'}].map((x,i)=>({...x,mine:true,created_at:'2026-11-11T00:00:0'+i+'Z'}));
window.omgSupabase={rpc(name,args){
 const value=(async()=>{
  if(args?.p_action==='download_info')return {data:{ok:true,byte_length:3145728,part_size:1048576,mime_type:'video/mp4'}};
  if(args?.p_action==='download_part'){window.partCalls++;await new Promise(r=>window.partWaiters.push(r));return {data:{ok:true,byte_length:3145728,mime_type:'video/mp4',part_index:args.p_data.part_index,chunk:btoa('x'.repeat(1048576))}};}
  return {data:{ok:true,can_send:true,profile:{display_name:'테스트'},messages:rows}};
 })();
 return {then:(resolve,reject)=>value.then(resolve,reject),abortSignal(signal){return Promise.race([value,new Promise((resolve,reject)=>{if(signal.aborted)reject(Error('cancelled'));else signal.addEventListener('abort',()=>reject(Error('cancelled')),{once:true});})]);}};
}};
window.viewerPlayCalls=0;HTMLMediaElement.prototype.load=function(){};HTMLMediaElement.prototype.pause=function(){};HTMLMediaElement.prototype.play=function(){if(this.id==='photoViewerVideo')window.viewerPlayCalls++;return Promise.reject(Error('fixture waits for data'));};
`;
const server=http.createServer((req,res)=>{const f=path.join(root,new URL(req.url,'http://local').pathname);try{res.setHeader('content-type',f.endsWith('.js')?'application/javascript':f.endsWith('.css')?'text/css':f.endsWith('.html')?'text/html':f.endsWith('.webp')?'image/webp':'application/octet-stream');res.end(fs.readFileSync(f));}catch{res.writeHead(404);res.end();}});
(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port;const browser=await chromium.launch();try{for(const width of [320,390,900]){
 const page=await browser.newPage({viewport:{width,height:860}});
 await page.route('**/*',r=>{const u=new URL(r.request().url());if(!r.request().url().startsWith(base))return r.fulfill({body:''});if(u.pathname==='/supabase-client.js')return r.fulfill({contentType:'application/javascript',body:fixture});if(['/guest-support-client.js','/notification-client.js','/chat-live.js'].includes(u.pathname))return r.fulfill({body:''});return r.continue();});
 await page.goto(base+'/staff-chat.html?peer='+peer);await page.locator('[data-photo="photo"]').click();
 assert(await page.locator('#mediaLoading').isHidden());assert.equal(await page.locator('#photoStage').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(0, 0, 0)');
 for(const id of ['photoViewerClose','photoGalleryOpen','photoPrevious','photoNext'])assert.equal(await page.locator('#'+id).evaluate(e=>getComputedStyle(e).backgroundColor),'rgba(0, 0, 0, 0)');
 assert(await page.locator('#photoNext').isVisible());await page.screenshot({path:'/tmp/oms-media-photo-'+width+'.png'});
 await page.locator('#photoNext').click();await page.waitForFunction(()=>partWaiters.length===1);assert.equal(await page.locator('#mediaPercent').textContent(),'0%');
 await page.evaluate(()=>partWaiters.shift()());await page.waitForFunction(()=>document.getElementById('mediaPercent').textContent==='33%');
 assert.equal(await page.locator('#mediaLoading').getAttribute('aria-valuenow'),'33');assert.equal(await page.locator('#mediaLoadingBytes').textContent(),'1.0 / 3.0 MB');
 await page.screenshot({path:'/tmp/oms-media-loading-'+width+'.png'});
 await page.locator('#mediaLoadingCancel').click();await page.waitForFunction(()=>document.getElementById('photoViewer').hidden);const calls=await page.evaluate(()=>partCalls);
 await page.evaluate(()=>partWaiters.shift()?.());await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>partCalls),calls,'cancel prevents next part');
 assert(await page.locator('#mediaLoading').isHidden());
 await page.locator('[data-video-load="video"]').click();
 for(let part=0;part<3;part++){await page.waitForFunction(()=>partWaiters.length===1);await page.evaluate(()=>partWaiters.shift()());}
 await page.waitForFunction(()=>document.getElementById('photoViewerVideo').getAttribute('src')?.startsWith('blob:'));
 await page.evaluate(()=>document.getElementById('photoViewerVideo').dispatchEvent(new Event('loadeddata')));
 assert.equal(await page.evaluate(()=>viewerPlayCalls),0,'opening a video never starts playback');
 assert(await page.locator('#photoViewerVideo').evaluate(v=>v.paused&&v.controls&&!v.autoplay));
 await page.locator('#photoPrevious').click();await page.locator('[data-photo-index="1"]').click();
 await page.waitForFunction(()=>document.getElementById('photoViewerVideo').getAttribute('src')?.startsWith('blob:'));
 assert.equal(await page.evaluate(()=>viewerPlayCalls),0,'thumbnail selection never starts playback');
 await page.locator('#photoViewerClose').click();
 console.log('PASS black viewer, bare controls, photo no loader, true 33%, cancellation '+width+'px');await page.close();
 }}finally{await browser.close();server.close();}})().catch(e=>{console.error(e);server.close();process.exitCode=1});
