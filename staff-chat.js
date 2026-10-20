(async()=>{
 const $=id=>document.getElementById(id),e=GuestSupport.esc,params=new URLSearchParams(location.search),peer=params.get('peer');
 let session,messages=[],busy=false,sending=false,timer,delay=2000,priority='normal',pending=null,started=false,photo=null,preparing=false,loadNotice=false,canSend=false;
 let receiptCursor=0,readBusy=false,readTimer,outbox,live,refreshAgain=false,enqueueing=false,fetched=false;
 function outboxChanged(){if(!outbox)return;for(const item of outbox.items(peer))if(item.message)mergeMessages([{...item.message,...(item.photo?{photo:item.photo}:{})}]);render();syncComposer();}
 function displayMessages(){const ids=new Set(messages.map(m=>m.client_id).filter(Boolean));return [...messages,...(outbox?.items(peer)||[]).filter(x=>!ids.has(x.client_id)&&!messages.some(m=>m.id===x.message_id)).map(x=>({id:'local:'+x.client_id,client_id:x.client_id,body:x.body,photo:x.photo,priority:x.priority,created_at:x.created_at,mine:true,pending:x.status,attachment_type:x.photo?.slice(5,x.photo.indexOf(';'))}))];}
 function refreshNow(){if(busy){refreshAgain=true;return;}clearTimeout(timer);load();}

 let peerProfile=null,viewerIndex=0,galleryLoading=false,galleryComplete=false;const videoUrls=new Map(),videoRequests=new Map(),videoPosters=new Map(),videoPosterRequests=new Map();let videoObserver,previewObserver,viewerVersion=0,viewerMediaId=null;
 const line=$('timeline'),input=$('body');
 function syncComposer(){$('send').disabled=!canSend||input.disabled||enqueueing||preparing||(!input.value.trim()&&!photo);}
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
 function receiptIds(){const pending=messages.filter(m=>m.mine&&!m.read_at);if(!pending.length)return [];const ids=Array.from({length:Math.min(200,pending.length)},(_,i)=>pending[(receiptCursor+i)%pending.length].id);receiptCursor=(receiptCursor+ids.length)%pending.length;return ids;}
 function mergeReceipts(receipts=[]){let changed=false;const byId=new Map(messages.map(m=>[m.id,m]));for(const receipt of receipts){const m=byId.get(receipt.id);if(m?.mine&&!m.read_at&&receipt.read_at){m.read_at=receipt.read_at;changed=true;}}return changed;}
 function showPeerProfile(){
  try{if(typeof window.OMGNative?.openWorkerProfile==='function'&&window.OMGNative.openWorkerProfile(peer)===true)return;}catch{}
  if(!peerProfile)return;$('peerProfileDialog').showModal?.()||$('peerProfileDialog').setAttribute('open','');
 }
 const isVideo=message=>/^video\//i.test(message.attachment_type||'')||/^data:video\//i.test(message.photo||'');
 const photos=()=>messages.filter(message=>message.photo||isVideo(message));
 function status(t='',bad=false){$('status').textContent=t;$('status').className='status'+(bad?' error':'');}
 function keepDraft(){try{sessionStorage.setItem(draftKey,JSON.stringify({body:input.value,priority,pending,photo}));}catch{}}
 function mergeMessages(incoming){const map=new Map(messages.map(message=>[message.id,message]));incoming.forEach(message=>{const old=map.get(message.id);map.set(message.id,old?.read_at&&!message.read_at?{...message,read_at:old.read_at}:message);});messages=[...map.values()].sort((a,b)=>a.created_at.localeCompare(b.created_at)||a.id.localeCompare(b.id));}
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
  if(started)render(true);
 }
 async function loadPeerProfile(){try{applyProfile(await StaffChat.profile(session,peer));}catch(error){console.warn('Staff profile load',error);}}
 function pruneVideoUrls(){for(const [id,url] of videoUrls){if(videoUrls.size<=6)break;if(String(id)===viewerMediaId||videoPosterRequests.has(id)||videoRequests.has(id))continue;URL.revokeObjectURL(url);videoUrls.delete(id);}}
 async function videoUrl(id){
  if(videoUrls.has(id))return videoUrls.get(id);
  if(videoRequests.has(id))return videoRequests.get(id);
  const request=(async()=>{
   const entry=messages.find(message=>String(message.id)===String(id));const result=/^data:video\//i.test(entry?.photo||'')?{attachment:entry.photo,mime_type:entry.photo.slice(5,entry.photo.indexOf(';'))}:await call('attachment',{message_id:id});
   if(!result?.attachment)throw new Error('동영상을 불러오지 못했습니다.');
   const encoded=result.attachment.split(',')[1]||'',binary=atob(encoded),bytes=new Uint8Array(binary.length);
   for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
   const url=URL.createObjectURL(new Blob([bytes],{type:result.mime_type||'video/webm'}));
   videoUrls.set(id,url);return url;
  })().finally(()=>{videoRequests.delete(id);pruneVideoUrls();});
  videoRequests.set(id,request);return request;
 }
 function videoPoster(url){return window.OMSVideoPreview.poster(url);}
 async function ensureVideoPoster(id){
  if(videoPosters.has(id))return videoPosters.get(id);
  if(videoPosterRequests.has(id))return videoPosterRequests.get(id);
  const request=(async()=>{const poster=await videoPoster(await videoUrl(id));if(poster)videoPosters.set(id,poster);return poster;})().finally(()=>{videoPosterRequests.delete(id);pruneVideoUrls();});
  videoPosterRequests.set(id,request);return request;
 }
 async function showVideoPoster(id,holder){
  try{const poster=await ensureVideoPoster(id);if(!holder.isConnected)return;const image=holder.querySelector('.video-poster');if(image&&poster){image.src=poster;image.hidden=false;holder.classList.add('has-poster');}}
  catch(error){if(holder.isConnected)holder.classList.add('preview-unavailable');console.warn('Video preview',error);}
 }
 function observePreviews(root){
  previewObserver?.disconnect();
  if(!previewObserver&&'IntersectionObserver' in window)previewObserver=new IntersectionObserver(entries=>{entries.forEach(entry=>{if(!entry.isIntersecting)return;previewObserver.unobserve(entry.target);showVideoPoster(entry.target.dataset.videoPreview,entry.target);});},{rootMargin:'120px'});
  root.querySelectorAll('[data-video-preview]').forEach(holder=>{const poster=videoPosters.get(holder.dataset.videoPreview),img=holder.querySelector('.video-poster');if(poster){img.src=poster;img.hidden=false;holder.classList.add('has-poster');}else if(previewObserver)previewObserver.observe(holder);else showVideoPoster(holder.dataset.videoPreview,holder);});
 }
 function mediaThumb(item){return isVideo(item)?'<img class="video-poster" alt="동영상 미리보기" hidden><span class="media-video-badge">▶</span>':'<img src="'+e(item.photo)+'" alt="사진" loading="lazy">';}
 function render(older=false){
  const near=line.scrollHeight-line.scrollTop-line.clientHeight<110,prev=line.scrollHeight;let day='';
  const markup=displayMessages().map(m=>{
   const d=new Date(m.created_at).toLocaleDateString('ko-KR'),label=d!==day?`<div class="day">${e(d)}</div>`:'';day=d;
   if(m.system)return label+`<div class="chat-system-event" data-id="${e(m.id)}">${e(m.body)}</div>`;
   const name=peerProfile?.display_name||'근무자',face=m.mine?'':`<button type="button" class="message-avatar" data-peer-profile aria-label="${e(name)} 근무자 정보 보기">${StaffChat.avatar(name,peerProfile?.profile_image)}</button>`;
   return label+`<div class="bubble-row ${m.mine?'mine':''}" data-id="${e(m.id)}">${face}<div class="message-copy">${m.mine?'':`<div class="bubble-name">${e(name)}</div>`}${m.priority==='urgent'?'<span class="staff-urgent">긴급</span>':''}${m.broadcast?'<span class="staff-broadcast">여러 사람에게 보낸 메세지</span>':''}<div class="message-line"><div class="bubble">${isVideo(m)?'<div class="chat-video"><img class="video-poster" alt="동영상 미리보기" hidden><button type="button" data-video-load="'+e(m.id)+'" aria-label="동영상 재생"><span class="video-play">▶</span><span class="video-label">동영상</span></button></div>':m.photo?`<img src="${e(m.photo)}" alt="첨부 사진" width="320" loading="lazy" style="aspect-ratio:4/3;object-fit:contain" data-photo="${e(m.id)}">`:''}${StaffChat.contractBody(m.body)}</div><div class="bubble-meta">${m.pending?`<button class="send-state" type="button" data-retry="${e(m.client_id)}">${m.pending==='failed'?'전송 실패 · 재시도':'전송 중…'}</button>`:!m.read_at?'<span class="message-unread" aria-label="안 읽은 사람 1명">1</span>':''}<time class="bubble-time">${e(new Date(m.created_at).toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit'}))}</time></div></div></div></div>`;
  }).join('')||'<div class="empty">첫 메세지를 보내 대화를 시작하세요.</div>';
  const bubbles=$('bubbles'),fragment=document.createElement('div');fragment.innerHTML=markup;
  const old=new Map([...bubbles.children].map((node,i)=>[node.dataset.id||'day:'+node.textContent,node]));
  let at=bubbles.firstChild;for(const fresh of [...fragment.children]){const key=fresh.dataset.id||'day:'+fresh.textContent;let node=old.get(key);old.delete(key);if(!node||node._markup!==fresh.outerHTML){node=fresh;node._markup=fresh.outerHTML;}if(node!==at)bubbles.insertBefore(node,at);at=node.nextSibling;}while(at){const next=at.nextSibling;at.remove();at=next;}for(const node of old.values())node.remove();
  bubbles.querySelectorAll('[data-retry]').forEach(button=>button.onclick=()=>outbox?.retry(button.dataset.retry));
  $('bubbles').querySelectorAll('[data-peer-profile]').forEach(button=>button.onclick=showPeerProfile);
  if(older)line.scrollTop+=line.scrollHeight-prev;else if(near||!started)line.scrollTop=line.scrollHeight;
  started=true;line.classList.remove('chat-loading');
  $('bubbles').querySelectorAll('[data-photo]').forEach(img=>img.onclick=()=>openViewerById(img.dataset.photo));
  videoObserver?.disconnect();
  if('IntersectionObserver' in window)videoObserver=new IntersectionObserver(entries=>{entries.forEach(entry=>{if(!entry.isIntersecting)return;videoObserver.unobserve(entry.target);showVideoPoster(entry.target.dataset.messageId,entry.target);});},{root:line,rootMargin:'160px'});
  $('bubbles').querySelectorAll('[data-video-load]').forEach(button=>{const id=button.dataset.videoLoad,holder=button.closest('.chat-video');holder.dataset.messageId=id;const poster=videoPosters.get(id);if(poster){const image=holder.querySelector('.video-poster');image.src=poster;image.hidden=false;holder.classList.add('has-poster');}else if(videoObserver)videoObserver.observe(holder);else showVideoPoster(id,holder);button.onclick=()=>openViewerById(id);});paintSearch();
 }
 function scheduleRead(){clearTimeout(readTimer);readTimer=setTimeout(()=>markRead().catch(error=>console.warn('Read receipt',error)),300);}
 let readThroughId='';
 async function markRead(){
  if(readBusy||document.hidden||!document.hasFocus()||!$('photoViewer').hidden||$('peerProfileDialog').open)return;
  const anchor=messages.at(-1);if(!anchor||anchor.id===readThroughId)return;readBusy=true;
  try{await call('read_room',{through_id:anchor.id});readThroughId=anchor.id;
   const seen=messages.filter(m=>!m.mine&&(m.created_at<anchor.created_at||m.created_at===anchor.created_at&&m.id<=anchor.id));
   const confirmed=new Set(seen.map(m=>m.id));for(const m of seen)m.read_at=new Date().toISOString();
   for(const row of $('bubbles').querySelectorAll('[data-id]'))if(confirmed.has(row.dataset.id))row.querySelector('.message-unread')?.remove();
   try{window.OMGNative?.refreshMessageBadge?.();}catch(_){}window.dispatchEvent(new Event('omg:messages-changed'));
  }finally{readBusy=false;}
 }
 line.addEventListener('scroll',scheduleRead,{passive:true});addEventListener('focus',scheduleRead);
 async function load(older=false){
  if(busy||document.hidden||searchLoading){clearTimeout(timer);timer=setTimeout(load,2000);return;}busy=true;clearTimeout(timer);
  try{
   const initial=!fetched,last=fetched?messages.at(-1):null,first=messages[0];
   const cursor=older&&first?{before_time:first.created_at,before_id:first.id}:last?{after_time:last.created_at,after_id:last.id}:{};
   const v=await call('messages',{...cursor,receipt_ids:receiptIds()});
   if(loadNotice){status('');loadNotice=false;}
   if(v.peer&&!peerProfile)applyProfile(v.peer);
   canSend=v.can_send===true;input.disabled=!canSend;syncComposer();
   if(!v.can_send)status('현재 이 계정에 메세지를 보낼 수 없습니다.',true);
   fetched=true;mergeMessages(v.messages);await outbox?.acknowledge(v.messages);const receiptChanged=mergeReceipts(v.receipts);if(older||initial)$('older').hidden=v.messages.length<50;if(v.messages.length||!started||receiptChanged)render(older);
   await markRead();scheduleRead();delay=!older&&v.messages.length===50?50:live?.connected?30000:2500;
  }catch(err){line.classList.remove('chat-loading');console.warn('Staff chat load',err);loadNotice=true;status('데이터를 불러오는 중입니다.');delay=Math.min(delay*2,30000);}
  finally{busy=false;if(refreshAgain){refreshAgain=false;timer=setTimeout(load,0);}else timer=setTimeout(load,delay);}
 }
 function renderPhoto(){syncComposer();const el=$('photoPending'),video=String(photo||'').startsWith('data:video/');el.hidden=!photo;el.innerHTML=photo?(video?'<video muted playsinline controls></video><span>동영상 첨부 (20MB 이하)</span><button type="button" aria-label="첨부 취소">×</button>':'<img alt="선택한 사진"><span>사진 첨부</span><button type="button" aria-label="첨부 취소">×</button>'):'';if(photo){el.querySelector(video?'video':'img').src=photo;el.querySelector('button').onclick=()=>{if(sending)return;photo=null;pending=null;renderPhoto();keepDraft();};}}
 function resetVideo(){const video=$('photoViewerVideo');video.onloadeddata=video.onerror=video.ontimeupdate=video.onplaying=null;video.pause();video.removeAttribute('src');video.removeAttribute('poster');video.load();video.hidden=true;$('videoFullscreen').hidden=true;$('videoViewerStatus').hidden=true;$('videoViewerRetry').hidden=true;$('photoStage').classList.remove('is-video');$('photoViewer').classList.remove('video-expanded');$('videoFullscreen').setAttribute('aria-pressed','false');$('videoFullscreen').setAttribute('aria-label','동영상 화면 확대');$('videoFullscreen').textContent='⛶';}
 async function renderViewer(autoplay=false){
  const list=photos(),item=list[viewerIndex];if(!item){closeViewer();return;}
  const version=++viewerVersion;viewerMediaId=String(item.id);resetVideo();const video=isVideo(item),stage=$('photoStage');
  photoZoom.setKey(String(item.id));photoZoom.setEnabled(!video);$('photoViewerImage').hidden=video;
  $('photoViewerName').textContent=item.mine?'나':peerProfile?.display_name||'대화 상대';
  $('photoViewerDate').textContent=new Date(item.created_at).toLocaleString('ko-KR',{year:'numeric',month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'});
  $('photoCount').textContent=`${list.length}개 중 ${viewerIndex+1}번째 · ${video?'동영상':'사진'}`;
  $('photoPrevious').disabled=viewerIndex===0;$('photoNext').disabled=viewerIndex===list.length-1;
  $('photoThumbs').innerHTML=list.map((entry,index)=>`<button type="button" class="${index===viewerIndex?'active':''}" data-photo-index="${index}" ${isVideo(entry)?'data-video-preview="'+e(entry.id)+'"':''} aria-label="${index+1}번째 ${isVideo(entry)?'동영상':'사진'}">${mediaThumb(entry)}</button>`).join('');
  $('photoThumbs').querySelectorAll('[data-photo-index]').forEach(button=>button.onclick=()=>{viewerIndex=Number(button.dataset.photoIndex);renderViewer();});observePreviews($('photoThumbs'));
  $('photoThumbs').querySelector('.active')?.scrollIntoView?.({block:'nearest',inline:'center'});
  if(!video){$('photoViewerImage').src=item.photo;return;}
  $('photoViewerImage').removeAttribute('src');stage.classList.add('is-video');$('videoFullscreen').hidden=false;
  const player=$('photoViewerVideo');player.hidden=false;$('videoViewerStatus').textContent='동영상을 불러오는 중…';$('videoViewerStatus').hidden=false;
  const cached=videoPosters.get(String(item.id));if(cached)player.poster=cached;
  try{const url=await videoUrl(item.id);if(version!==viewerVersion||$('photoViewer').hidden)return;player.src=url;player.onloadeddata=()=>{if(version===viewerVersion)$('videoViewerStatus').hidden=true;};player.onerror=()=>{if(version!==viewerVersion)return;$('videoViewerStatus').textContent='동영상을 재생하지 못했습니다.';$('videoViewerStatus').hidden=false;$('videoViewerRetry').hidden=false;};player.ontimeupdate=()=>{if(version!==viewerVersion||player.currentTime<.08)return;const poster=window.OMSVideoPreview.frame(player);if(!poster)return;videoPosters.set(String(item.id),poster);player.poster=poster;player.ontimeupdate=null;document.querySelectorAll('.chat-video,[data-video-preview]').forEach(holder=>{if(String(holder.dataset.messageId||holder.dataset.videoPreview)!==String(item.id))return;const image=holder.querySelector('.video-poster');if(image){image.src=poster;image.hidden=false;holder.classList.add('has-poster');}});};player.onplaying=()=>{if(version===viewerVersion)$('videoViewerStatus').hidden=true;};player.load();ensureVideoPoster(item.id).then(poster=>{if(version===viewerVersion&&poster)player.poster=poster;}).catch(()=>{});if(autoplay){try{await player.play();if(version===viewerVersion)$('videoViewerStatus').hidden=true;}catch{if(version===viewerVersion){$('videoViewerStatus').textContent='재생 버튼을 눌러주세요.';}}}}
  catch(error){if(version!==viewerVersion)return;$('videoViewerStatus').textContent=error.message||'동영상을 불러오지 못했습니다.';$('videoViewerRetry').hidden=false;}
 }
 function openViewerById(id){const list=photos(),index=list.findIndex(item=>String(item.id)===String(id));if(index<0)return;if($('photoViewer').hidden)history.pushState({...history.state,staffMediaViewer:true},'',location.href);viewerIndex=index;$('photoViewer').hidden=false;document.body.classList.add('media-open');renderViewer(true);$('photoViewerClose').focus();}
 function closeViewer(fromHistory=false){if(document.fullscreenElement){document.exitFullscreen?.().catch(()=>{});}viewerVersion++;viewerMediaId=null;resetVideo();photoZoom.reset();$('photoGallery').hidden=true;$('photoViewer').hidden=true;document.body.classList.remove('media-open');$('photoViewerImage').removeAttribute('src');if(!fromHistory&&history.state?.staffMediaViewer)history.go(history.state.staffMediaGallery?-2:-1);}
 function moveViewer(step){const next=viewerIndex+step;if(next<0||next>=photos().length)return;viewerIndex=next;renderViewer();}
 function closeGallery(fromHistory=false){$('photoGallery').hidden=true;if(!fromHistory&&history.state?.staffMediaGallery)history.back();}
 function renderGallery(){const list=photos();$('galleryCount').textContent=`${list.length}개`;$('galleryStatus').textContent=list.length?'':'대화에 사진이나 동영상이 없습니다.';$('photoGrid').innerHTML=list.map((item,index)=>`<button type="button" data-gallery-index="${index}" ${isVideo(item)?'data-video-preview="'+e(item.id)+'"':''} aria-label="${index+1}번째 ${isVideo(item)?'동영상':'사진'} 열기">${mediaThumb(item)}<time>${e(new Date(item.created_at).toLocaleDateString('ko-KR',{month:'numeric',day:'numeric'}))}</time></button>`).join('');$('photoGrid').querySelectorAll('[data-gallery-index]').forEach(button=>button.onclick=()=>{viewerIndex=Number(button.dataset.galleryIndex);closeGallery();renderViewer();});observePreviews($('photoGrid'));}
 async function loadAllPhotos(){
  if(galleryComplete||galleryLoading)return;galleryLoading=true;clearTimeout(timer);$('galleryStatus').textContent='사진·동영상을 불러오는 중입니다.';
  try{
   let first=messages[0],pages=0;
   while(first&&pages<100){const v=await call('messages',{before_time:first.created_at,before_id:first.id});mergeMessages(v.messages);pages++;if(v.messages.length<50){galleryComplete=true;break;}first=messages[0];}
   if(!first)galleryComplete=true;
  }catch(error){$('galleryStatus').textContent='미디어를 모두 불러오지 못했습니다. 다시 시도해주세요.';console.warn('Staff gallery load',error);}
  finally{galleryLoading=false;timer=setTimeout(load,delay);}
 }
 async function openGallery(){const currentId=photos()[viewerIndex]?.id;$('photoViewerVideo').pause();if($('photoGallery').hidden)history.pushState({...history.state,staffMediaGallery:true},'',location.href);$('photoGallery').hidden=false;$('galleryStatus').textContent='사진·동영상을 불러오는 중입니다.';renderGallery();await loadAllPhotos();const currentIndex=photos().findIndex(item=>item.id===currentId);if(currentIndex>=0)viewerIndex=currentIndex;renderGallery();}

 $('photoInput').onchange=async event=>{const file=event.target.files[0];if(!file||sending)return;preparing=true;$('send').disabled=true;try{status(file.type.startsWith('video/')?'동영상 압축 중…':'사진 압축 중…');const compressed=await window.OMGPhoto.media(file);const isVideo=compressed.type==='video/webm';if(!isVideo&&!compressed.type.startsWith('image/'))throw Error('사진이나 동영상을 선택해주세요.');if(isVideo&&compressed.size>20*1024*1024)throw Error('동영상은 압축 후 20MB 이하로 선택해주세요.');if(!isVideo&&compressed.size>1572864)throw Error('사진은 압축 후 1.5MB 이하로 선택해주세요.');photo=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(compressed);});pending=null;renderPhoto();keepDraft();status('');}catch(err){status(err.message||'사진을 불러오지 못했습니다.',true);}finally{preparing=false;event.target.value='';syncComposer();}};
 $('older').onclick=()=>load(true);
 $('priority').onclick=()=>{if(sending)return;priority=priority==='urgent'?'normal':'urgent';$('priority').textContent=priority==='urgent'?'긴급⌄':'일반⌄';$('priority').setAttribute('aria-pressed',String(priority==='urgent'));keepDraft();};
 function resizeComposer(){input.style.height='auto';const height=input.scrollHeight;input.style.height=Math.max(44,Math.min(110,height))+'px';input.style.overflowY=height>110?'auto':'hidden';}
 input.oninput=()=>{syncComposer();resizeComposer();keepDraft();};
 $('composer').onsubmit=async event=>{
  event.preventDefault();const originalText=input.value,attachment=photo,body=originalText.trim()||(attachment?(attachment.startsWith('data:video/')?'동영상':'사진'):'');
  if(!canSend||!body||preparing||enqueueing||!outbox)return;enqueueing=true;syncComposer();
  try{await outbox.enqueue({peer,body,priority,photo:attachment});if(input.value===originalText)input.value='';if(photo===attachment)photo=null;pending=null;renderPhoto();keepDraft();status('');line.scrollTop=line.scrollHeight;}
  catch(error){status('보낼 메시지를 보관하지 못했습니다. 저장 공간을 확인하고 다시 시도해주세요.',true);}
  finally{enqueueing=false;syncComposer();resizeComposer();}
 };
 $('peerIdentity').onclick=showPeerProfile;
 $('peerProfileClose').onclick=()=>$('peerProfileDialog').close?.()||$('peerProfileDialog').removeAttribute('open');
 $('photoViewerClose').onclick=()=>closeViewer();$('photoPrevious').onclick=()=>moveViewer(-1);$('photoNext').onclick=()=>moveViewer(1);$('photoGalleryOpen').onclick=openGallery;$('photoGalleryClose').onclick=()=>closeGallery();
 const photoZoom=OMSPhotoZoom.attach($('photoStage'),$('photoViewerImage'),{onSwipe:moveViewer});
 $('videoViewerRetry').onclick=()=>renderViewer(true);
 $('videoFullscreen').onclick=async()=>{const viewer=$('photoViewer'),expanded=!viewer.classList.contains('video-expanded');viewer.classList.toggle('video-expanded',expanded);$('videoFullscreen').setAttribute('aria-pressed',String(expanded));$('videoFullscreen').textContent=expanded?'⤢':'⛶';$('videoFullscreen').setAttribute('aria-label',expanded?'동영상 화면 축소':'동영상 화면 확대');if(expanded){try{await $('photoStage').requestFullscreen?.();}catch{}}else if(document.fullscreenElement){try{await document.exitFullscreen();}catch{}}};
 document.addEventListener('fullscreenchange',()=>{if(!document.fullscreenElement){$('photoViewer').classList.remove('video-expanded');$('videoFullscreen').setAttribute('aria-pressed','false');$('videoFullscreen').setAttribute('aria-label','동영상 화면 확대');$('videoFullscreen').textContent='⛶';}});
 let videoSwipe=null;$('photoStage').addEventListener('pointerdown',event=>{if(!$('photoStage').classList.contains('is-video')||event.target.closest('button')||event.button!==0)return;const box=$('photoStage').getBoundingClientRect();if(event.clientY>box.bottom-62)return;videoSwipe={x:event.clientX,y:event.clientY,id:event.pointerId};});$('photoStage').addEventListener('pointerup',event=>{if(!videoSwipe||event.pointerId!==videoSwipe.id)return;const dx=event.clientX-videoSwipe.x,dy=event.clientY-videoSwipe.y;videoSwipe=null;if(Math.abs(dx)>50&&Math.abs(dx)>Math.abs(dy)*1.5)moveViewer(dx<0?1:-1);});$('photoStage').addEventListener('pointercancel',()=>videoSwipe=null);
 addEventListener('popstate',()=>{if(!$('photoViewer').hidden&&!history.state?.staffMediaViewer)closeViewer(true);else if(!$('photoGallery').hidden&&!history.state?.staffMediaGallery)closeGallery(true);});
 document.addEventListener('keydown',event=>{if(!$('photoGallery').hidden&&event.key==='Escape'){closeGallery();return;}if($('photoViewer').hidden)return;if(event.key==='Escape')closeViewer();else if(event.key==='ArrowLeft')moveViewer(-1);else if(event.key==='ArrowRight')moveViewer(1);});
 addEventListener('pagehide',()=>{videoObserver?.disconnect();previewObserver?.disconnect();viewerVersion++;$('photoViewerVideo').pause();for(const url of videoUrls.values())URL.revokeObjectURL(url);videoUrls.clear();});
 document.addEventListener('visibilitychange',()=>{clearTimeout(timer);if(!document.hidden)load();});addEventListener('online',()=>load());addEventListener('pagehide',()=>{clearTimeout(timer);clearTimeout(readTimer);keepDraft();});
 try{
  session=await omgSession.require({allowCompleted:true});if(!session)return;if(!/^(owner|employee):[0-9a-f-]{36}$/i.test(peer||''))throw new Error('대화 상대를 선택해주세요.');
  if(StaffChat.nativeOpen?.(peer)){location.replace('messages.html?tab=staff');return;}
  draftKey='staff-chat:'+session.accessToken+':'+peer;try{const draft=JSON.parse(sessionStorage.getItem(draftKey)||'null');if(draft){input.value=draft.body||'';pending=draft.pending;photo=draft.photo||null;renderPhoto();if(draft.priority==='urgent')$('priority').click();}}catch{}
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(session.accessToken));
  const scope=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
  outbox=await OMSChatOutbox.open(scope,async item=>StaffChat.call(session,'send',{peer:item.peer,body:item.body,priority:item.priority,photo:item.photo,client_id:item.client_id}),outboxChanged);
  outboxChanged();live=window.OMSChatLive?.connect(session,()=>{refreshNow();outbox.pump();try{window.OMGNative?.refreshMessageBadge?.();}catch{}});
  addEventListener('pagehide',()=>{live?.close();outbox?.close();});
  await Promise.all([loadPeerProfile(),load()]);
 }catch(err){line.classList.remove('chat-loading');status(err.message,true);$('send').disabled=true;}
})();
