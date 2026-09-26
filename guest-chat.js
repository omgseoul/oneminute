(async()=>{
 const G=GuestSupport,q=new URLSearchParams(location.search),slug=q.get('p'),isGuest=!!slug;
 let auth,roomId=q.get('room'),seq=0,busy=false,timer,failures=0,actor,room,asset=null,pending=null,lastDay='',lastRead=0,roomLoaded=false,sending=false,uploading=false,lastRetry=0;
 const timeline=document.getElementById('timeline'),body=document.getElementById('body'),send=document.getElementById('send');
 if(isGuest){const s=JSON.parse(localStorage.getItem('omg_guest_'+slug)||'null');if(!s){location.replace('guest.html?p='+encodeURIComponent(slug));return;}auth={guest_token:s.guest_token};roomId=s.room_id;document.getElementById('back').href='guest.html?p='+encodeURIComponent(slug);document.getElementById('back').textContent='‹ 숙소 안내';}
 else{const s=await omgSession.require({allowCompleted:true});if(!s)return;auth={access_token:s.accessToken};}
 const call=(action,data={})=>G.call(action,{room_id:roomId,...data},auth);
 const draftKey='omg_chat_draft_'+roomId;body.value=sessionStorage.getItem(draftKey)||'';body.oninput=()=>{pending=null;sessionStorage.setItem(draftKey,body.value);body.style.height='auto';body.style.height=Math.min(body.scrollHeight,110)+'px';};
 function renderMeta(){
  document.getElementById('roomTitle').textContent=isGuest?room.property_name:room.guest_name;
  document.getElementById('roomInfo').textContent=isGuest?'직원과 대화 · 답변을 확인하려면 이 화면을 열어두세요.':`${room.property_name} · ${room.room_number||'객실 미정'} · ${room.check_in} ~ ${room.check_out}`;
  document.getElementById('assignment').textContent=room.status==='closed'?'대화 종료':room.assigned_name?(isGuest?'직원 대응 중':room.assigned_name+' 대응 중'):'담당자 대기';
  send.disabled=sending||uploading||!room.chat_enabled||room.status==='closed';
  if(!room.chat_enabled)G.message('현재 채팅 운영이 중지되어 있습니다. 기존 대화는 볼 수 있습니다.');
  else if(room.status==='closed')G.message('종료된 대화입니다. 직원이 다시 열면 대화할 수 있습니다.');
  if(!isGuest){const controls=document.getElementById('controls');controls.hidden=false;controls.replaceChildren();
   const button=(label,action,data={})=>{const b=document.createElement('button');b.className='btn';b.textContent=label;b.onclick=async()=>{b.disabled=true;try{await call(action,data);await poll();}catch(e){G.message(e.message,true);b.disabled=false;}};controls.append(b);};
   if(room.assigned_key===actor)button('담당 해제','release');else if(room.assigned_key)button('내가 인계받기','claim',{takeover:true});else button('내가 대응하기','claim');
   button(room.status==='closed'?'대화 다시 열기':'대화 종료',room.status==='closed'?'reopen':'close');
  }
 }
 function append(m,assets){
  const day=new Date(m.created_at).toLocaleDateString('ko-KR',{month:'long',day:'numeric'});if(day!==lastDay){const d=document.createElement('div');d.className='day';d.textContent=day;timeline.append(d);lastDay=day;}
  const el=document.createElement('div');
  if(m.sender_kind==='system'){el.className='system-message';el.textContent=m.sender_name+' · '+m.body;timeline.append(el);return;}
  const mine=isGuest?m.sender_kind==='guest':m.sender_key===actor;el.className='bubble-row'+(mine?' mine':'');
  const name=document.createElement('div');name.className='bubble-name';name.textContent=mine?'나':m.sender_name;el.append(name);
  const bubble=document.createElement('div');bubble.className='bubble';if(m.asset_id){const a=assets.find(x=>x.id===m.asset_id);if(a){const img=new Image();img.src=a.url;img.alt='첨부 사진';img.loading='lazy';img.onclick=async()=>{try{const fresh=await call('messages',{after_seq:Number(m.seq)-1});G.viewer(fresh.assets.find(x=>x.id===m.asset_id),'첨부 사진');}catch(e){G.message(e.message,true);}};bubble.append(img);}}
  if(m.body)bubble.append(document.createTextNode(m.body));el.append(bubble);const time=document.createElement('time');time.className='bubble-time';time.textContent=new Date(m.created_at).toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit'});el.append(time);timeline.append(el);
 }
 async function poll(){
  if(busy||document.hidden)return;busy=true;clearTimeout(timer);
  try{const nearBottom=timeline.scrollHeight-timeline.scrollTop-timeline.clientHeight<100;const v=await call('messages',{after_seq:seq});room=v.room;actor=v.actor_key;
   if(!roomLoaded){timeline.replaceChildren();roomLoaded=true;}for(const m of v.messages){append(m,v.assets||[]);seq=Math.max(seq,Number(m.seq));}
   failures=0;if(room.chat_enabled&&room.status==='open')G.message(navigator.onLine?'':'인터넷 연결을 기다리는 중입니다.');renderMeta();if(nearBottom)timeline.scrollTop=timeline.scrollHeight;
   if(!isGuest&&seq>lastRead&&document.hasFocus()){await call('read',{last_seq:seq});lastRead=seq;}
   timer=setTimeout(poll,v.messages.length===100?50:2000);
   if(Date.now()-lastRetry>95000){lastRetry=Date.now();call('retry_events').catch(()=>{});}
  }catch(e){failures++;G.message(e.message,true);timer=setTimeout(poll,Math.min(30000,2500*2**failures));}finally{busy=false;}
 }
 document.getElementById('photoInput').onchange=async e=>{const file=e.target.files[0];if(!file)return;uploading=true;send.disabled=true;G.message('사진을 올리고 있습니다…');try{const photo=await G.photo(file);const v=await G.call('upload',{room_id:roomId},auth,photo);asset=v.assets[0];pending=null;const el=document.getElementById('photoPending');el.hidden=false;el.innerHTML='<img alt="선택한 사진" src="'+G.esc(asset.url)+'"><span>사진 첨부</span><button class="icon-btn" type="button" aria-label="첨부 취소">×</button>';el.querySelector('button').onclick=()=>{asset=null;pending=null;el.hidden=true;};G.message('');}catch(err){G.message(err.message,true);}finally{uploading=false;send.disabled=sending||room?.status!=='open'||!room?.chat_enabled;e.target.value='';}};
 document.getElementById('composer').onsubmit=async e=>{e.preventDefault();if(send.disabled||(!body.value.trim()&&!asset))return;sending=true;send.disabled=true;body.disabled=true;G.message('보내는 중…');
  if(!pending)pending={client_id:crypto.randomUUID(),body:body.value,asset_id:asset?.id||null};
  try{const r=await call('send',pending);pending=null;asset=null;body.value='';sessionStorage.removeItem(draftKey);document.getElementById('photoPending').hidden=true;body.style.height='auto';await poll();timeline.scrollTop=timeline.scrollHeight;if(r.push_state==='pending')G.message('메시지는 저장됐습니다. 직원 알림은 재시도 중입니다.');}
  catch(err){G.message(err.message+' 전송을 다시 누르면 중복 없이 재시도합니다.',true);}finally{sending=false;body.disabled=false;send.disabled=uploading||room?.status!=='open'||!room?.chat_enabled;}
 };
 document.addEventListener('visibilitychange',()=>{clearTimeout(timer);if(!document.hidden)poll();});window.addEventListener('online',poll);window.addEventListener('focus',poll);await poll();
 if(!isGuest)call('retry_events').catch(()=>{});
})().catch(e=>GuestSupport.message(e.message,true));
