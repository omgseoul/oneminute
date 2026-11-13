const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const w=new JSDOM(fs.readFileSync('online.html','utf8').replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/online.html',runScripts:'outside-only',pretendToBeVisual:true}).window;
 const tick=()=>new Promise(r=>setTimeout(r,40)),calls=[];let failOther=false,release=null,delayHome=false;
 const branches=[{id:'home',name:'One Minute'},{id:'other',name:'OMG House'},{id:'unlinked',name:'Lazy Bear'}];
 w.omgSession={require:async()=>({sessionKind:'owner',propertyId:'home',accessToken:'test'})};w.OMG_SUPABASE={url:'https://fixture.test',publishableKey:'test'};w.AbortSignal=AbortSignal;w.setInterval=()=>1;
 w.fetch=async(u,o)=>{const {action,data}=JSON.parse(o.body),id=data.property_id||'home';calls.push({action,id});if(id==='other'&&failOther)return {ok:false,json:async()=>({ok:false,message:'Fixture unavailable'})};
  let result={ok:true};if(['settings','properties'].includes(action))result={...result,property_id:id,property_name:branches.find(p=>p.id===id).name,branches,beds_property_id:id==='unlinked'?null:123,properties:[],ai_mode:'off'};
  if(['bookings','sync_bookings'].includes(action)){if(delayHome&&id==='home'&&action==='sync_bookings'){delayHome=false;await new Promise(r=>release=r);}result={ok:true,bookings:[{id:123,guest_name:id==='home'?'19 Myung Paik':'20Ana Martínez',status:'confirmed',arrival:'2026-11-12',departure:'2026-11-18',channel:'Booking.com',room_name:'403',data:{numAdult:1,numChild:0}}]};}
  if(['inbox','sync_messages'].includes(action))result={ok:true,threads:[]};if(action==='logs')result={ok:true,logs:[]};return {ok:true,json:async()=>result};
 };
 for(const file of ['property-selector.js','select-picker.js','online.js'])w.eval(fs.readFileSync(file,'utf8'));
 await tick();w.document.querySelector('a[href="#checkin"]').click();await tick();
 const check=(id,value)=>{const el=w.document.querySelector('#propertyName input[data-value="'+id+'"]');el.checked=value;el.dispatchEvent(new w.Event('change'));};
 assert.equal(w.document.querySelectorAll('.booking-item').length,1);let row=w.document.querySelector('.booking-item');assert(!row.open);assert.equal(row.querySelector('.booking-name').textContent,'19 Myung Paik');assert.equal(row.querySelector('.booking-channel').textContent,'Booking');assert.equal(row.querySelector('.booking-dates').textContent,'11.12–11.18');assert.equal(row.querySelector('.booking-property').textContent,'One Minute');assert(row.querySelector('.inbox-chevron'));row.open=true;
 w.document.querySelector('#searchButton').click();await tick();assert(w.document.querySelector('.booking-item').open,'refresh preserves expanded booking');
 check('other',true);await tick();assert.equal(w.document.querySelectorAll('.booking-item').length,2);assert.equal(new Set([...w.document.querySelectorAll('.booking-item')].map(x=>x.dataset.booking)).size,2);assert.equal(w.document.querySelector('#propertyName button').textContent,'2개 지점 선택');
 failOther=true;w.document.querySelector('#searchButton').click();await tick();assert.equal(w.document.querySelectorAll('.booking-item').length,2,'unavailable branch retains last cached rows');assert.match(w.document.querySelector('#status').textContent,/OMG House: 연결 지연/);failOther=false;
 check('other',false);await tick();delayHome=true;w.document.querySelector('#searchButton').click();await tick();assert(release);
 check('home',false);check('other',true);await tick();assert.equal(w.document.querySelector('.booking-property').textContent,'OMG House');release();await tick();assert.equal(w.document.querySelectorAll('.booking-item').length,1);assert.equal(w.document.querySelector('.booking-property').textContent,'OMG House','late result from previous selection cannot replace current branch');
 check('other',false);await tick();assert.equal(w.document.querySelectorAll('.booking-item').length,0);
 check('unlinked',true);await tick();assert(!calls.some(c=>c.id==='unlinked'&&c.action==='sync_bookings'));assert.match(w.document.querySelector('#bookingFreshness').textContent,/Lazy Bear: 기본정보/);
 w.close();console.log('Multi-property reservation rows, duplicate IDs, partial failure, empty selection, stale response exclusion and unlinked branches passed.');
})().catch(e=>{console.error(e);process.exit(1)});
