(async()=>{
 await window.openGuestEmailLink?.();
 const G=GuestSupport,q=new URLSearchParams(location.search),slug=q.get('p'),isGuest=!!slug;
 let auth,roomId=q.get('room'),seq=0,busy=false,timer,failures=0,actor,room,asset=null,pending=null,lastDay='',lastRead=0,roomLoaded=false,sending=false,uploading=false,lastRetry=0;
 let chatMessages=[],photoAssets=new Map(),viewerIndex=0,refreshingPhotos=null;
 const timeline=document.getElementById('timeline'),body=document.getElementById('body'),send=document.getElementById('send'),$=id=>document.getElementById(id);
 if(isGuest){document.body.classList.add('guest-facing-chat');const s=JSON.parse(localStorage.getItem('omg_guest_'+slug)||'null');if(!s){location.replace('guest.html?p='+encodeURIComponent(slug));return;}auth={guest_token:s.guest_token};roomId=s.room_id;$('back').href='guest.html?p='+encodeURIComponent(slug);$('back').textContent='‹ 숙소 안내';}
 else{const s=await omgSession.require({allowCompleted:true});if(!s)return;auth={access_token:s.accessToken};}
 const call=(action,data={})=>G.call(action,{room_id:roomId,...data},auth);
 const draftKey='omg_chat_draft_'+roomId;body.value=sessionStorage.getItem(draftKey)||'';body.oninput=()=>{pending=null;sessionStorage.setItem(draftKey,body.value);body.style.height='auto';body.style.height=Math.min(body.scrollHeight,110)+'px';};
 const mine=m=>isGuest?m.sender_kind==='guest':m.sender_key===actor;
 function remember(messages,assets=[]){
  assets.forEach(item=>photoAssets.set(String(item.id),item));
  const known=new Map(chatMessages.map(message=>[String(message.id),message]));
  messages.forEach(message=>known.set(String(message.id),message));
  chatMessages=[...known.values()].sort((a,b)=>Number(a.seq)-Number(b.seq));
 }
 function syncBubblePhotos(){timeline.querySelectorAll('[data-photo-message]').forEach(image=>{const message=chatMessages.find(item=>String(item.id)===image.dataset.photoMessage),item=message&&photoAssets.get(String(message.asset_id));if(item&&image.src!==item.url)image.src=item.url;});}
 const photos=()=>chatMessages.filter(message=>message.asset_id&&photoAssets.has(String(message.asset_id))).map(message=>({message,asset:photoAssets.get(String(message.asset_id))}));
 function renderMeta(){
  $('roomTitle').textContent=isGuest?room.property_name:room.guest_name+' · '+(room.room_number||'객실 미정');
  const info=$('roomInfo');
  if(isGuest)info.textContent='직원과 대화 · 답변을 확인하려면 이 화면을 열어두세요.';
  else{
   info.replaceChildren(document.createTextNode(`${room.property_name} · ${room.room_number||'객실 미정'} · ${room.check_in} ~ ${room.check_out}`));
   if(room.email){const link=document.createElement('a');link.className='guest-email-link';link.href='mailto:'+room.email;link.textContent=room.email;link.title=room.email+'에게 메일 보내기';info.append(document.createTextNode(' · '),link);}
  }
  const status=$('assignment');status.textContent=isGuest?'':window.omgGuestReplyStatus(room);status.hidden=!status.textContent;
  send.disabled=sending||uploading||!room.chat_enabled;
  if(!room.chat_enabled)G.message('현재 채팅 운영이 중지되어 있습니다. 기존 대화는 볼 수 있습니다.');
  renderAIControls();
 }
 let aiControlKey='';
 function renderAIControls(){
  const key=[isGuest,room.status,room.ai_handoff,room.ai_paused,room.ai_active,room.assigned_key].join(':');if(key===aiControlKey)return;aiControlKey=key;
  const host=$('controls');host.replaceChildren();host.className='chat-controls ai-chat-controls';host.hidden=isGuest||room.status!=='open';if(host.hidden)return;
  const actions=room.ai_paused||room.assigned_key?[['ai_resume','AI 자동답변 재개']]:[['claim','직접 대응하기']];
  actions.forEach(([action,label])=>{const b=document.createElement('button');b.type='button';b.className='ai-chat-control'+(action==='ai_urgent'?' urgent':'');b.textContent=label;b.onclick=()=>showAIAction(action,label);host.append(b);});
 }
 function showAIAction(action,label){
  const d=document.createElement('dialog');d.innerHTML='<div class="top"><h2></h2><button type="button" class="icon-btn" aria-label="닫기">×</button></div><p class="help"></p><div class="row"><button type="button" class="btn grow">취소 / Cancel</button><button type="button" class="btn primary grow">확인 / Confirm</button></div><p class="status" role="status"></p>';
  d.querySelector('h2').textContent=label;d.querySelector('.help').textContent=action==='ai_urgent'?'관리자와 근무중인 직원에게 긴급 알림을 요청합니다. 즉시 위험한 경우 현지 긴급기관에 직접 연락해주세요. / Request urgent staff assistance. In immediate danger, contact local emergency services.':action==='ai_human'?'직원 연결을 요청하고 이 대화의 AI 자동답변을 멈춥니다. / Request staff assistance and pause AI replies.':action==='ai_resume'?'직원 대응을 해제하고 다음 메시지부터 설정된 조건에 따라 AI가 답변합니다.':'이 대화의 AI 답변을 멈추고 직접 대응합니다.';
  const buttons=d.querySelectorAll('button');buttons[0].onclick=buttons[1].onclick=()=>d.close();buttons[2].onclick=async()=>{buttons[2].disabled=true;try{const result=await call(action);d.querySelector('.status').textContent=result.push_state==='pending'?'요청이 저장되었습니다. 알림 전달을 재시도 중입니다. / Request saved. Retrying notification delivery.':'요청을 처리했습니다. / Request submitted.';await poll();buttons[1].textContent='닫기 / Close';buttons[2].hidden=true;}catch(e){d.querySelector('.status').textContent=e.message;buttons[2].disabled=false;}};d.onclose=()=>d.remove();document.body.append(d);d.showModal();
 }
 function append(m){
  const day=new Date(m.created_at).toLocaleDateString('ko-KR',{month:'long',day:'numeric'});if(day!==lastDay){const d=document.createElement('div');d.className='day';d.textContent=day;timeline.append(d);lastDay=day;}
  if(m.sender_kind==='system')return;
  const el=document.createElement('div');el.className='bubble-row'+(mine(m)?' mine':'');
  const name=document.createElement('div');name.className='bubble-name';name.textContent=m.sender_kind==='ai'?'직원':mine(m)?'나':m.sender_name;if(m.sender_kind==='ai'){const badge=document.createElement('span');badge.className='ai-sender-badge';badge.textContent='AI';badge.setAttribute('aria-label','AI 자동답변');name.append(badge);}el.append(name);
  const bubble=document.createElement('div');bubble.className='bubble';
  if(m.asset_id){const item=photoAssets.get(String(m.asset_id));if(item){const img=new Image();img.src=item.url;img.alt='첨부 사진';img.loading='lazy';img.width=320;img.style.aspectRatio='4/3';img.style.objectFit='contain';img.dataset.photoMessage=String(m.id);img.onclick=()=>openViewerById(m.id);bubble.append(img);}}
  if(m.body)bubble.append(document.createTextNode(m.body));const line=document.createElement('div');line.className='guest-message-line';line.append(bubble);el.append(line);const time=document.createElement('time');time.className='bubble-time';time.textContent=new Date(m.created_at).toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit'});line.append(time);timeline.append(el);
 }
 function renderViewer(){
  const list=photos(),item=list[viewerIndex];if(!item){closeViewer();return;}
  photoZoom.setKey(String(item.message.id));$('photoViewerImage').src=item.asset.url;
  $('photoViewerName').textContent=mine(item.message)?'나':item.message.sender_name||(isGuest?'직원':room?.guest_name||'게스트');
  $('photoViewerDate').textContent=new Date(item.message.created_at).toLocaleString('ko-KR',{year:'numeric',month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'});
  $('photoCount').textContent=`${list.length}장 중 ${viewerIndex+1}번째`;
  $('photoPrevious').disabled=viewerIndex===0;$('photoNext').disabled=viewerIndex===list.length-1;
  $('photoThumbs').innerHTML=list.map((entry,index)=>`<button type="button" class="${index===viewerIndex?'active':''}" data-photo-index="${index}" aria-label="${index+1}번째 사진"><img src="${G.esc(entry.asset.url)}" alt=""></button>`).join('');
  $('photoThumbs').querySelectorAll('[data-photo-index]').forEach(button=>button.onclick=()=>{viewerIndex=Number(button.dataset.photoIndex);renderViewer();});
  $('photoThumbs').querySelector('.active')?.scrollIntoView?.({block:'nearest',inline:'center'});
 }
 function openViewerById(id){const list=photos(),index=list.findIndex(item=>String(item.message.id)===String(id));if(index<0)return;viewerIndex=index;$('photoViewer').hidden=false;document.body.classList.add('media-open');renderViewer();$('photoViewerClose').focus();refreshPhotoUrls(id).catch(error=>console.warn('Guest photo refresh',error));}
 function closeViewer(){photoZoom.reset();$('photoGallery').hidden=true;$('photoViewer').hidden=true;document.body.classList.remove('media-open');$('photoViewerImage').removeAttribute('src');}
 function moveViewer(step){const next=viewerIndex+step;if(next<0||next>=photos().length)return;viewerIndex=next;renderViewer();}
 function renderGallery(){const list=photos();$('galleryCount').textContent=`${list.length}장`;$('galleryStatus').textContent=list.length?'':'대화에 사진이 없습니다.';$('photoGrid').innerHTML=list.map((item,index)=>`<button type="button" data-gallery-index="${index}" aria-label="${index+1}번째 사진 열기"><img src="${G.esc(item.asset.url)}" alt="대화 사진" loading="lazy"><time>${G.esc(new Date(item.message.created_at).toLocaleDateString('ko-KR',{month:'numeric',day:'numeric'}))}</time></button>`).join('');$('photoGrid').querySelectorAll('[data-gallery-index]').forEach(button=>button.onclick=()=>{viewerIndex=Number(button.dataset.galleryIndex);$('photoGallery').hidden=true;renderViewer();});}
 async function refreshPhotoUrls(currentId){
  if(!refreshingPhotos)refreshingPhotos=(async()=>{let cursor=0,pages=0;while(pages<100){const value=await call('messages',{after_seq:cursor});remember(value.messages,value.assets||[]);pages++;if(value.messages.length<100)break;cursor=Number(value.messages.at(-1).seq);}})().finally(()=>{refreshingPhotos=null;});
  await refreshingPhotos;
  syncBubblePhotos();
  if(currentId){const current=photos().findIndex(item=>String(item.message.id)===String(currentId));if(current>=0)viewerIndex=current;}
  if(!$('photoViewer').hidden)renderViewer();if(!$('photoGallery').hidden)renderGallery();
 }
 async function openGallery(){const currentId=photos()[viewerIndex]?.message.id;$('photoGallery').hidden=false;$('galleryStatus').textContent='사진을 불러오는 중입니다.';renderGallery();try{await refreshPhotoUrls(currentId);}catch(error){$('galleryStatus').textContent='사진을 모두 불러오지 못했습니다. 다시 시도해주세요.';console.warn('Guest gallery load',error);}}
 async function poll(){
  if(busy||document.hidden)return;busy=true;clearTimeout(timer);
  try{const firstLoad=timeline.classList.contains('chat-loading');const nearBottom=timeline.scrollHeight-timeline.scrollTop-timeline.clientHeight<100;const v=await call('messages',{after_seq:seq});room=v.room;actor=v.actor_key;remember(v.messages,v.assets||[]);
   if(!roomLoaded){timeline.replaceChildren();roomLoaded=true;}for(const m of v.messages){append(m);seq=Math.max(seq,Number(m.seq));}
   failures=0;if(room.chat_enabled)G.message(navigator.onLine?'':'인터넷 연결을 기다리는 중입니다.');renderMeta();if(nearBottom||firstLoad)timeline.scrollTop=timeline.scrollHeight;if(v.messages.length<100)timeline.classList.remove('chat-loading');
   if(!isGuest&&seq>lastRead&&document.hasFocus()){await call('read',{last_seq:seq});lastRead=seq;try{window.OMGNative?.refreshMessageBadge?.();}catch(_){}}
   if(!$('photoGallery').hidden)renderGallery();
   timer=setTimeout(poll,v.messages.length===100?50:2000);
   if(Date.now()-lastRetry>95000){lastRetry=Date.now();call('retry_events').catch(()=>{});}
  }catch(e){timeline.classList.remove('chat-loading');failures++;console.warn('Guest chat load',e);G.message('데이터를 불러오는 중입니다.');timer=setTimeout(poll,Math.min(30000,2500*2**failures));}finally{busy=false;}
 }
 $('photoInput').onchange=async e=>{const file=e.target.files[0];if(!file)return;uploading=true;send.disabled=true;G.message('사진을 올리고 있습니다…');try{const photo=await G.photo(file);if(photo.size>1572864)throw new Error('사진은 압축 후 1.5MB 이하로 선택해주세요.');const v=await G.call('upload',{room_id:roomId},auth,photo);asset=v.assets[0];pending=null;const el=$('photoPending');el.hidden=false;el.innerHTML='<img alt="선택한 사진" src="'+G.esc(asset.url)+'"><span>사진 첨부</span><button class="icon-btn" type="button" aria-label="첨부 취소">×</button>';el.querySelector('button').onclick=()=>{asset=null;pending=null;el.hidden=true;};G.message('');}catch(err){G.message(err.message,true);}finally{uploading=false;send.disabled=sending||!room?.chat_enabled;e.target.value='';}};
 $('composer').onsubmit=async e=>{e.preventDefault();if(send.disabled||(!body.value.trim()&&!asset))return;sending=true;send.disabled=true;body.disabled=true;G.message('보내는 중…');
  if(!pending)pending={client_id:crypto.randomUUID(),body:body.value,asset_id:asset?.id||null};
  try{const r=await call('send',pending);pending=null;asset=null;body.value='';sessionStorage.removeItem(draftKey);$('photoPending').hidden=true;body.style.height='auto';await poll();timeline.scrollTop=timeline.scrollHeight;if(r.push_state==='pending')G.message('메시지는 저장됐습니다. 직원 알림은 재시도 중입니다.');}
  catch(err){G.message(err.message+' 전송을 다시 누르면 중복 없이 재시도합니다.',true);}finally{sending=false;body.disabled=false;send.disabled=uploading||!room?.chat_enabled;}
 };
 $('photoViewerClose').onclick=closeViewer;$('photoPrevious').onclick=()=>moveViewer(-1);$('photoNext').onclick=()=>moveViewer(1);$('photoGalleryOpen').onclick=openGallery;$('photoGalleryClose').onclick=()=>$('photoGallery').hidden=true;
 const photoZoom=OMSPhotoZoom.attach($('photoStage'),$('photoViewerImage'),{onSwipe:moveViewer});
 document.addEventListener('keydown',event=>{if(!$('photoGallery').hidden&&event.key==='Escape'){$('photoGallery').hidden=true;return;}if($('photoViewer').hidden)return;if(event.key==='Escape')closeViewer();else if(event.key==='ArrowLeft')moveViewer(-1);else if(event.key==='ArrowRight')moveViewer(1);});
 document.addEventListener('visibilitychange',()=>{clearTimeout(timer);if(!document.hidden)poll();});window.addEventListener('online',poll);window.addEventListener('focus',poll);await poll();
 if(!isGuest)call('retry_events').catch(()=>{});
})().catch(e=>GuestSupport.message(e.message,true));
