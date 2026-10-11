/* Profile lookup shares the staff chat permission-checked RPC. */
window.MessageProfiles=(()=>{
 const $=id=>document.getElementById(id),e=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 let dialog,revision=0,active=null,returnFocus=null,request=0;
 function avatar(name,image){return `<span class="detail-avatar">${image?`<img src="${e(image)}" alt="${e(name)} 프로필 사진">`:e(String(name||'?').trim().charAt(0))}</span>`;}
 function paint(profile){
  $('messageProfileAvatar').innerHTML=avatar(profile.display_name,profile.profile_image);
  $('messageProfileName').textContent=profile.display_name||'근무자';
  for(const [id,key] of [['messageProfileDisplayName','display_name'],['messageProfileJob','job_title'],['messageProfileProperty','property_name'],['messageProfilePhone','contact_phone']])$(id).textContent=profile[key]||'-';
 }
 function ensure(){
  if(dialog)return;dialog=document.createElement('dialog');dialog.id='messageProfile';dialog.setAttribute('aria-labelledby','messageProfileTitle');
  dialog.innerHTML='<div class="mp-top"><h2 id="messageProfileTitle">근무자 정보</h2><button id="messageProfileClose" type="button" aria-label="근무자 정보 닫기">×</button></div><div class="mp-person"><div id="messageProfileAvatar"></div><strong id="messageProfileName"></strong></div><dl><div><dt>이름</dt><dd id="messageProfileDisplayName"></dd></div><div><dt>직무</dt><dd id="messageProfileJob"></dd></div><div><dt>지점</dt><dd id="messageProfileProperty"></dd></div><div><dt>연락처</dt><dd id="messageProfilePhone"></dd></div></dl><p id="messageProfileStatus" role="status"></p><button id="messageProfileRetry" type="button" hidden>다시 불러오기</button>';
  document.body.append(dialog);$('messageProfileClose').onclick=close;$('messageProfileRetry').onclick=()=>load(active);
  dialog.addEventListener('cancel',event=>{event.preventDefault();close();});dialog.addEventListener('click',event=>{if(event.target===dialog){const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close();}});
 }
 async function load(entry){
  const version=++request;$('messageProfileStatus').textContent='정보를 불러오는 중입니다.';$('messageProfileRetry').hidden=true;
  try{const profile=await StaffChat.profile(entry.session,entry.peer);if(active!==entry||version!==request)return;entry.profile=profile;paint(profile);$('messageProfileStatus').textContent='';}
  catch(error){if(active!==entry||version!==request)return;$('messageProfileStatus').textContent=error.message||'근무자 정보를 불러오지 못했습니다.';$('messageProfileRetry').hidden=false;}
 }
 function open(entry,button){ensure();active=entry;returnFocus=button;paint(entry.profile||{display_name:entry.name,profile_image:entry.image});history.pushState({...history.state,omgWorkerProfile:true},'',location.href);dialog.showModal();load(entry);}
 function close(){if(dialog?.open)history.back();}
 function restore(){if(!dialog?.open)return false;request++;active=null;dialog.close();returnFocus?.focus();return true;}
 function bind(item,session,recipients=[]){
  const version=++revision,meta=$('detailMeta');if(!meta)return;
  let people=[];
  if(!item.is_sender){const peer=item.sender_employee_id?'employee:'+item.sender_employee_id:item.sender_owner_id?'owner:'+item.sender_owner_id:null;if(peer)people=[{peer,name:item.sender_label,image:item.sender_profile_image}];}
  else people=(item.recipient_labels||[]).flatMap(name=>{const matches=recipients.filter(r=>r.display_name===name);return matches.length===1?[{peer:matches[0].recipient_key,name,image:matches[0].profile_image}]:[];});
  if(!people.length)return;
  const time=meta.querySelector('small')?.textContent||'';
  meta.classList.add('mp-identities');meta.innerHTML='';
  people.forEach(person=>{
   const entry={...person,session},button=document.createElement('button');button.type='button';button.className='mp-identity';button.setAttribute('aria-label',person.name+' 근무자 정보 보기');
   const render=profile=>{button.innerHTML=avatar(profile.display_name||person.name,profile.profile_image)+`<span class="detail-who"><b>${e(person.name)}</b><small>${e(time)}</small></span><span class="mp-chevron" aria-hidden="true">›</span>`;};
   render({profile_image:person.image});button.onclick=()=>open(entry,button);meta.append(button);
   StaffChat.profile(session,person.peer).then(profile=>{if(version!==revision||!button.isConnected)return;entry.profile=profile;render(profile);}).catch(()=>{});
  });
 }
 return {bind,restore};
})();
