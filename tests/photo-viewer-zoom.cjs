const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const w=new JSDOM('<div id="stage"><img id="image"></div>',{runScripts:'outside-only'}).window;
const stage=w.document.getElementById('stage'),img=w.document.getElementById('image');stage.getBoundingClientRect=()=>({left:0,top:0,width:400,height:300});Object.defineProperties(img,{naturalWidth:{value:800},naturalHeight:{value:600}});
w.eval(fs.readFileSync('photo-viewer-zoom.js','utf8'));let moves=[];const zoom=w.OMSPhotoZoom.attach(stage,img,{onSwipe:s=>moves.push(s)});zoom.setKey('first');
const pointer=(type,id,x,y,pointerType='touch')=>{const ev=new w.Event(type,{bubbles:true,cancelable:true});Object.assign(ev,{pointerId:id,clientX:x,clientY:y,button:0,pointerType});stage.dispatchEvent(ev);};
const pct=()=>stage.querySelector('.photo-zoom-reset').textContent;
pointer('pointerdown',1,100,150);pointer('pointerdown',2,300,150);pointer('pointermove',2,400,150);assert.equal(pct(),'150%');pointer('pointerup',2,400,150);pointer('pointermove',1,140,170);pointer('pointerup',1,140,170);assert(zoom.zoomed);assert.deepEqual(moves,[]);
pointer('pointerdown',1,100,100);pointer('pointermove',1,10000,10000);pointer('pointerup',1,10000,10000);assert.equal(img.style.transform,'translate(100px, 75px) scale(1.5)');assert.deepEqual(moves,[]);
zoom.setKey('first');assert.equal(pct(),'150%');zoom.setKey('second');assert.equal(pct(),'100%');assert(!zoom.zoomed);
pointer('pointerdown',1,250,100);pointer('pointerup',1,150,103);assert.deepEqual(moves,[1]);pointer('pointerdown',1,100,100);pointer('pointerup',1,110,230);assert.deepEqual(moves,[1]);
pointer('pointerdown',1,200,150);pointer('pointerup',1,200,150);pointer('pointerdown',1,200,150);pointer('pointerup',1,200,150);assert.equal(pct(),'250%');assert(zoom.zoomed);
zoom.reset();stage.dispatchEvent(new w.MouseEvent('dblclick',{clientX:200,clientY:150,bubbles:true}));assert.equal(pct(),'250%');stage.dispatchEvent(new w.MouseEvent('dblclick',{clientX:200,clientY:150,bubbles:true}));assert.equal(pct(),'100%');
const buttons=stage.querySelectorAll('button');for(let i=0;i<10;i++)buttons[2].click();assert.equal(pct(),'500%');assert(buttons[2].disabled);buttons[1].click();assert.equal(pct(),'100%');assert(buttons[0].disabled);
const ev=new w.WheelEvent('wheel',{deltaY:-200,clientX:200,clientY:150,cancelable:true});stage.dispatchEvent(ev);assert(ev.defaultPrevented);assert(zoom.zoomed);zoom.reset();
pointer('pointerdown',1,250,100);pointer('pointercancel',1,100,100);assert.deepEqual(moves,[1]);assert.equal(pct(),'100%');
for(const [page,script,stageId,imageId] of [['staff-chat.html','staff-chat.js','photoStage','photoViewerImage'],['guest-chat.html','guest-chat.js','photoStage','photoViewerImage'],['messages.html','report-inbox.js','reportPhotoStage','reportPhotoFull']]){const html=fs.readFileSync(page,'utf8'),js=fs.readFileSync(script,'utf8');assert(html.indexOf('photo-viewer-zoom.js')<html.indexOf(script+'?'));assert(html.includes('photo-viewer-zoom.css'));assert(js.includes('OMSPhotoZoom'));assert(!js.includes("addEventListener('touchstart'"));assert(js.includes(stageId)&&js.includes(imageId));}
w.close();console.log('Pinch, bounded pan, double tap/click, zoom controls, wheel, swipe isolation, cancel, stable refresh/reset and all three integrations passed.');
