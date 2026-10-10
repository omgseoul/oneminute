(async()=>{
 const $=id=>document.getElementById(id),e=GuestSupport.esc,params=new URLSearchParams(location.search),peer=params.get('peer');
 let session,messages=[],busy=false,sending=false,timer,delay=2000,priority='normal',pending=null,started=false,photo=null,preparing=false,loadNotice=false;
 let peerProfile=null,viewerIndex=0,touchStartX=null,galleryLoading=false,galleryComplete=false;
 const line=$('timeline'),input=$('body');
 let searchVersion=0,searchIds=[],searchIndex=-1,searchQuery='',searchLoading=false;
 function paintSearch(){
  const q=searchQuery.trim().toLowerCase();searchIds=q?messages.filter(m=>StaffChat.cleanText(m.body).toLowerCase().includes(q)).map(m=>m.id):[];
  if(searchIndex<0||searchIndex>=searchIds.length)searchIndex=searchIds.length-1;
  $('bubbles').querySelectorAll('.bubble-row').forEach(row=>{row.classList.toggle('search-match',searchIds.includes(row.dataset.id));row.classList.toggle('search-current',row.dataset.id===searchIds[searchIndex]);});
  $('chatSearchStatus').textContent=searchLoading?'이전 대화에서 검색 중…':q?(searchIds.length?`${searchIndex+1} / ${searchIds.length}`:'검색 결과가 없습니다.'):'검색어를 입력해주세요.';
  $('chatSearchPrev').disabled=searchIndex<=0;$('chatSearchNext').disabled=searchIndex<0||searchIndex>=searchIds.length-1;
 }
 function focusMatch(){paintSearch();const id=searchIds[searchIndex];if(!id)return;const node=[...$('bubbles').querySelectorAll('[data-id]')].find(row=>row.dataset.id===id);node?.scrollIntoView({block:'center',behavior:'smooth'});}
 async function runSearch(){
  const version=++searchVersion;searchQuery=$('chatSearchInput').value.trim();searchIndex=-1;
  if(!searchQuery){paintSearch();return;}if(!session)return;searchLoading=true;paintSearch();
  try{let pages=0;while(version===searchVersion&&!galleryComplete&&messages.length&&pages<20){const first=messages[0],v=await call('messages',{before_time:first.created_at,before_id:first.id});if(version!==searchVersion)return;mergeMessages(v.messages);pages++;if(v.messages.length<50)galleryComplete=true;render(true);}
   if(version!==searchVersion)return;searchLoading=false;searchIndex=-1;render(true);focusMatch();if(!galleryComplete){$('chatSearchStatus').textContent+=' · 검색을 다시 누르면 이전 대화도 검색';}
  }catch(error){if(version===searchVersion){searchLoading=false;paintSearch();$('chatSearchStatus').textContent='검색을 완료하지 못했습니다. 다시 눌러주세요.';}}
 }
 function closeSearch(){searchVersion++;searchLoading=false;searchQuery='';searchIds=[];searchIndex=-1;$('chatSearchPanel').hidden=true;$('chatSearchToggle').setAttribute('aria-expanded','false');paintSearch();}
 $('chatSearchToggle').onclick=()=>{if(!$('chatSearchPanel').hidden){closeSearch();return;}$('chatSearchPanel').hidden=false;$('chatSearchToggle').setAttribute('aria-expanded','true');$('chatSearchInput').focus();};
 $('chatSearchClose').onclick=closeSearch;$('chatSearchRun').onclick=runSearch;
 $('chatSearchInput').oninput=()=>{searchVersion++;searchLoading=false;searchQuery=$('chatSearchInput').value.trim();searchIndex=-1;paintSearch();focusMatch();};
 $('chatSearchInput').onkeydown=ev=>{if(ev.key==='Enter'){ev.preventDefault();runSearch();}if(ev.key==='Escape')closeSearch();};
 $('chatSearchPrev').onclick=()=>{if(searchIndex>0){searchIndex--;focusMatch();}};$('chatSearchNext').onclick=()=>{if(searchIndex<searchIds.length-1){searchIndex++;focusMatch();}};

 if(params.get('from')==='home'){document.querySelector('.back').href='app.html';document.querySelector('.back').textContent='← Home';}
 let draftKey='';
 const call=(a,d={})=>StaffChat.call(session,a,{peer,...d});
 const photos=()=>messages.filter(message=>message.photo);
 function status(t='',bad=false){$('status').textContent=t;$('status').className='status'+(bad?' error':'');}
 function keepDraft(){try{sessionStorage.setItem(draftKey,JSON.stringify({body:input.value,priority,pending,photo}));}catch{}}
 function mergeMessages(incoming){const map=new Map(messages.map(message=>[message.id,message]));incoming.forEach(message=>map.set(message.id,message));messages=[...map.values()].sort((a,b)=>a.created_at.localeCompare(b.created_at)||a.id.localeCompare(b.id));}
 function applyProfile(profile){
  if(!profile)return;peerProfile={...peerProfile,...profile};
  $('roomTitle').textContent=peerProfile.display_name||'대화 상대';
  $('peerAvatar').innerHTML=StaffChat.avatar(peerProfile.display_name,peerProfile.profile_image);
  $('peerProfileAvatar').innerHTML=StaffChat.avatar(peerProfile.display_name,peerProfile.profile_image);
  $('peerProfileName').textContent=peerProfile.display_name||'근무자';
  $('peerProfileDisplayName').textContent=peerProfile.display_name||'-';
  $('peerProfileJobTitle').textContent=peerProfile.job_title||'-';
  $('peerProfileProperty').textContent=peerProfile.property_name||'-';
  $('peerProfilePhone').textContent=peerProfile.contact_phone||'-';
 }
 async function loadPeerProfile(){try{applyProfile(await StaffChat.profile(session,peer));}catch(error){console.warn('Staff profile load',error);}}
 function render(older=false){
  const near=line.scrollHeight-line.scrollTop-line.clientHeight<110,prev=line.scrollHeight;let day='';
  $('bubbles').innerHTML=messages.map(m=>{const d=new Date(m.created_at).toLocaleDateString('ko-KR'),label=d!==day?`<div class="day">${e(d)}</div>`:'';day=d;return label+`<div class="bubble-row ${m.mine?'mine':''}" data-id="${e(m.id)}">${m.priority==='urgent'?'<span class="staff-urgent">긴급</span>':''}${m.broadcast?'<span class="staff-broadcast">여러 사람에게 보낸 메세지</span>':''}<div class="bubble">${m.photo?`<img src="${e(m.photo)}" alt="첨부 사진" width="320" loading="lazy" style="aspect-ratio:4/3;object-fit:contain" data-photo="${e(m.id)}">`:''}${StaffChat.contractBody(m.body)}</div><div class="bubble-time">${e(new Date(m.created_at).toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit'}))}</div></div>`;}).join('')||'<div class="empty">첫 메세지를 보내 대화를 시작하세요.</div>';
  if(older)line.scrollTop+=line.scrollHeight-prev;else if(near||!started)line.scrollTop=line.scrollHeight;
  started=true;line.classList.remove('chat-loading');
  $('bubbles').querySelectorAll('[data-photo]').forEach(img=>img.onclick=()=>openViewerById(img.dataset.photo));paintSearch();
 }
 async function markRead(){const ids=messages.filter(m=>!m.mine&&!m.read_at).map(m=>m.id);if(ids.length&&!document.hidden){await call('read',{ids});messages.forEach(m=>{if(ids.includes(m.id))m.read_at=new Date().toISOString();});}}
 async function load(older=false){
  if(busy||document.hidden||searchLoading){clearTimeout(timer);timer=setTimeout(load,2000);return;}busy=true;clearTimeout(timer);
  try{
   const last=messages.at(-1),first=messages[0];
   const v=await call('messages',older&&first?{before_time:first.created_at,before_id:first.id}:last?{after_time:last.created_at,after_id:last.id}:{});
   if(loadNotice){status('');loadNotice=false;}
   applyProfile({...v.peer,...peerProfile});
   $('send').disabled=!v.can_send||sending||preparing;input.disabled=!v.can_send;
   if(!v.can_send)status('현재 이 계정에 메세지를 보낼 수 없습니다.',true);
   mergeMessages(v.messages);if(older||!started)$('older').hidden=v.messages.length<50;if(v.messages.length||!started)render(older);
   await markRead();delay=!older&&v.messages.length===50?50:2000;
  }catch(err){line.classList.remove('chat-loading');console.warn('Staff chat load',err);loadNotice=true;status('데이터를 불러오는 중입니다.');delay=Math.min(delay*2,30000);}
  finally{busy=false;timer=setTimeout(load,delay);}
 }
 function renderPhoto(){const el=$('photoPending');el.hidden=!photo;el.innerHTML=photo?'<img alt="선택한 사진"><span>사진 첨부</span><button type="button" aria-label="첨부 취소">×</button>':'';if(photo){el.querySelector('img').src=photo;el.querySelector('button').onclick=()=>{if(sending)return;photo=null;pending=null;renderPhoto();keepDraft();};}}
 function renderViewer(){
  const list=photos(),item=list[viewerIndex];if(!item){closeViewer();return;}
  $('photoViewerImage').src=item.photo;$('photoViewerName').textContent=item.mine?'나':peerProfile?.display_name||'대화 상대';
  $('photoViewerDate').textContent=new Date(item.created_at).toLocaleString('ko-KR',{year:'numeric',month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'});
  $('photoCount').textContent=`${list.length}장 중 ${viewerIndex+1}번째`;
  $('photoPrevious').disabled=viewerIndex===0;$('photoNext').disabled=viewerIndex===list.length-1;
  $('photoThumbs').innerHTML=list.map((entry,index)=>`<button type="button" class="${index===viewerIndex?'active':''}" data-photo-index="${index}" aria-label="${index+1}번째 사진"><img src="${e(entry.photo)}" alt=""></button>`).join('');
  $('photoThumbs').querySelectorAll('[data-photo-index]').forEach(button=>button.onclick=()=>{viewerIndex=Number(button.dataset.photoIndex);renderViewer();});
  const active=$('photoThumbs').querySelector('.active');if(active?.scrollIntoView)active.scrollIntoView({block:'nearest',inline:'center'});
 }
 function openViewerById(id){const list=photos(),index=list.findIndex(item=>String(item.id)===String(id));if(index<0)return;viewerIndex=index;$('photoViewer').hidden=false;document.body.classList.add('media-open');renderViewer();$('photoViewerClose').focus();}
 function closeViewer(){$('photoGallery').hidden=true;$('photoViewer').hidden=true;document.body.classList.remove('media-open');$('photoViewerImage').removeAttribute('src');}
 function moveViewer(step){const next=viewerIndex+step;if(next<0||next>=photos().length)return;viewerIndex=next;renderViewer();}
 function renderGallery(){const list=photos();$('galleryCount').textContent=`${list.length}장`;$('galleryStatus').textContent=list.length?'':'대화에 사진이 없습니다.';$('photoGrid').innerHTML=list.map((item,index)=>`<button type="button" data-gallery-index="${index}" aria-label="${index+1}번째 사진 열기"><img src="${e(item.photo)}" alt="대화 사진" loading="lazy"><time>${e(new Date(item.created_at).toLocaleDateString('ko-KR',{month:'numeric',day:'numeric'}))}</time></button>`).join('');$('photoGrid').querySelectorAll('[data-gallery-index]').forEach(button=>button.onclick=()=>{viewerIndex=Number(button.dataset.galleryIndex);$('photoGallery').hidden=true;renderViewer();});}
 async function loadAllPhotos(){
  if(galleryComplete||galleryLoading)return;galleryLoading=true;clearTimeout(timer);$('galleryStatus').textContent='사진을 불러오는 중입니다.';
  try{
   let first=messages[0],pages=0;
   while(first&&pages<100){const v=await call('messages',{before_time:first.created_at,before_id:first.id});mergeMessages(v.messages);pages++;if(v.messages.length<50){galleryComplete=true;break;}first=messages[0];}
   if(!first)galleryComplete=true;
  }catch(error){$('galleryStatus').textContent='사진을 모두 불러오지 못했습니다. 다시 시도해주세요.';console.warn('Staff gallery load',error);}
  finally{galleryLoading=false;timer=setTimeout(load,delay);}
 }
 async function openGallery(){const currentId=photos()[viewerIndex]?.id;$('photoGallery').hidden=false;$('galleryStatus').textContent='사진을 불러오는 중입니다.';renderGallery();await loadAllPhotos();const currentIndex=photos().findIndex(item=>item.id===currentId);if(currentIndex>=0)viewerIndex=currentIndex;renderGallery();}

 $('photoInput').onchange=async event=>{const file=event.target.files[0];if(!file||sending)return;preparing=true;$('send').disabled=true;try{const compressed=await GuestSupport.photo(file);if(!compressed.type.startsWith('image/'))throw Error('사진을 선택해주세요.');if(compressed.size>1572864)throw Error('사진은 압축 후 1.5MB 이하로 선택해주세요.');photo=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(compressed);});pending=null;renderPhoto();keepDraft();status('');}catch(err){status(err.message||'사진을 불러오지 못했습니다.',true);}finally{preparing=false;event.target.value='';$('send').disabled=input.disabled||sending;}};
 $('older').onclick=()=>load(true);
 $('priority').onclick=()=>{if(sending)return;priority=priority==='urgent'?'normal':'urgent';$('priority').textContent=priority==='urgent'?'긴급⌄':'일반⌄';$('priority').setAttribute('aria-pressed',String(priority==='urgent'));keepDraft();};
 input.oninput=()=>{input.style.height='auto';input.style.height=Math.min(110,input.scrollHeight)+'px';keepDraft();};
 $('composer').onsubmit=async event=>{event.preventDefault();const originalText=input.value;const body=input.value.trim()||(photo?'사진':'');if((!body&&!photo)||sending||preparing)return;sending=true;$('send').disabled=true;status('보내는 중…');if(!pending||pending.body!==body||pending.priority!==priority||pending.photo!==photo)pending={body,priority,photo,client_id:crypto.randomUUID()};keepDraft();try{const result=await call('send',pending);if(input.value===originalText)input.value='';photo=null;renderPhoto();pending=null;keepDraft();status('');try{if(!result.duplicate)await window.omgNotifications.send(session.accessToken,result.message_id);}catch{status('메세지는 저장됐지만 알림 전달을 확인하지 못했습니다.',true);}await load();}catch(err){status(err.message,true);}finally{sending=false;$('send').disabled=input.disabled;input.style.height='auto';}};
 $('peerIdentity').onclick=()=>{if(!peerProfile)return;$('peerProfileDialog').showModal?.()||$('peerProfileDialog').setAttribute('open','');};
 $('peerProfileClose').onclick=()=>$('peerProfileDialog').close?.()||$('peerProfileDialog').removeAttribute('open');
 $('photoViewerClose').onclick=closeViewer;$('photoPrevious').onclick=()=>moveViewer(-1);$('photoNext').onclick=()=>moveViewer(1);$('photoGalleryOpen').onclick=openGallery;$('photoGalleryClose').onclick=()=>$('photoGallery').hidden=true;
 $('photoStage').addEventListener('touchstart',event=>{touchStartX=event.changedTouches[0]?.clientX??null;},{passive:true});
 $('photoStage').addEventListener('touchend',event=>{if(touchStartX===null)return;const distance=(event.changedTouches[0]?.clientX??touchStartX)-touchStartX;touchStartX=null;if(Math.abs(distance)>45)moveViewer(distance<0?1:-1);},{passive:true});
 document.addEventListener('keydown',event=>{if(!$('photoGallery').hidden&&event.key==='Escape'){$('photoGallery').hidden=true;return;}if($('photoViewer').hidden)return;if(event.key==='Escape')closeViewer();else if(event.key==='ArrowLeft')moveViewer(-1);else if(event.key==='ArrowRight')moveViewer(1);});
 document.addEventListener('visibilitychange',()=>{clearTimeout(timer);if(!document.hidden)load();});addEventListener('online',()=>load());addEventListener('pagehide',()=>{clearTimeout(timer);keepDraft();});
 try{
  session=await omgSession.require({allowCompleted:true});if(!session)return;if(!/^(owner|employee):[0-9a-f-]{36}$/i.test(peer||''))throw new Error('대화 상대를 선택해주세요.');
  draftKey='staff-chat:'+session.accessToken+':'+peer;try{const draft=JSON.parse(sessionStorage.getItem(draftKey)||'null');if(draft){input.value=draft.body||'';pending=draft.pending;photo=draft.photo||null;renderPhoto();if(draft.priority==='urgent')$('priority').click();}}catch{}
  await Promise.all([loadPeerProfile(),load()]);
 }catch(err){line.classList.remove('chat-loading');status(err.message,true);$('send').disabled=true;}
})();
