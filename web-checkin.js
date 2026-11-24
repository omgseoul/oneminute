window.WebCheckin=(()=>{
 const root=document.createElement('dialog');root.className='web-checkin-dialog';
 root.innerHTML=`<header><div><small class="wc-heading-note">GUEST WEB CHECK-IN</small><h2>웹체크인</h2></div><div class="wc-header-actions"><button type="button" class="wc-retry" hidden>재시도</button><button type="button" class="wc-close" aria-label="닫기">×</button></div></header>
 <details class="wc-preview-tools" hidden><summary>실제 예약 테스트 안내</summary><p class="wc-preview-info"></p><p class="wc-preview-day"></p><p>재시도를 누르면 새로운 테스트로 시작합니다. 실제 출입 비밀번호가 표시될 수 있습니다.</p></details>
 <div class="wc-progress" aria-label="진행 단계"><span>1 예약번호</span><span>2 숙박 날짜</span><span>3 예약자 확인</span></div>
 <form><section data-step="reference"><label>예약번호를 입력해주세요<small>Booking confirmation number</small><input name="reference" maxlength="80" minlength="1" autocomplete="off" required placeholder="예약확인서의 예약번호"></label><p class="wc-reference-note wc-attempt">3회 남음</p></section>
 <section data-step="name" hidden><label>예약자 이름을 입력해주세요<small>Name on your reservation</small><input name="name" maxlength="100" minlength="2" autocomplete="name" required placeholder="예약확인서에 표시된 이름"></label><p class="wc-name-note wc-attempt">3회 남음</p></section>
 <section data-step="dates" hidden><h3>체크인·체크아웃 날짜를 선택해주세요</h3><div class="wc-dates"><label>체크인 · Check-in<input type="date" name="check_in" required></label><label>체크아웃 · Check-out<input type="date" name="check_out" required></label></div></section>
 <section data-step="choice" hidden><h3>예약자 이름을 선택해주세요</h3><div class="wc-options"></div><p class="wc-choice-note wc-attempt">2회 남음</p></section>
 <section data-step="upload" hidden><h3>예약확정서 캡처를 올려주세요</h3><p class="wc-note">체크인·체크아웃 날짜와 예약자 이름 또는 예약번호가 보이게 캡처해주세요. 정보가 나뉘어 있으면 최대 2장을 함께 선택할 수 있습니다.</p><label class="wc-upload">예약확정서 이미지 선택 · 최대 2장<input type="file" name="document" multiple accept="image/jpeg,image/png,image/webp" required></label><p class="wc-file-name"></p><p class="wc-attempt">1회 남음 · 실패 시 직원 확인이 필요합니다.</p><p class="wc-note">확인에 필요한 이미지만 AI로 전송하며 OMS에 이미지 파일을 저장하지 않습니다.</p></section>
 <p class="wc-status" role="status" aria-live="polite"></p><div class="wc-actions"><button type="button" class="wc-unknown">모름</button><button type="submit" class="wc-next">다음 →</button></div></form>
 <section class="wc-result" hidden><span class="wc-success">✓ 예약 확인 완료</span><p class="wc-greeting"></p><h3></h3><p>객실 · Room</p><strong class="wc-room"></strong><p>출입 비밀번호 · Access code</p><strong class="wc-code"></strong><small>출입 정보는 다른 사람에게 공유하지 마세요.</small><button type="button" class="wc-done">확인</button></section><aside class="wc-preview-diagnostics" hidden aria-live="polite"><strong>테스트 확인 결과 · 관리자 전용</strong><p></p></aside><button type="button" class="wc-staff">직원과의 채팅 · Contact staff</button>`;
 document.body.append(root);const form=root.querySelector('form'),status=root.querySelector('.wc-status'),next=root.querySelector('.wc-next'),unknown=root.querySelector('.wc-unknown');
 let stage='reference',mode='reference',slug,chat,verificationToken,deviceId,generation=0,expiry,locked=false,busy=false,preview=null;
 const uuid=()=>{if(crypto.randomUUID)return crypto.randomUUID();const a=crypto.getRandomValues(new Uint8Array(16));a[6]=(a[6]&15)|64;a[8]=(a[8]&63)|128;const h=[...a].map(x=>x.toString(16).padStart(2,'0')).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);};
 function persistent(storage,key){let id=storage.getItem(key);if(!/^[a-f0-9-]{36}$/i.test(id||'')){id=uuid();storage.setItem(key,id);}return id;}
 function showDiagnostics(lines){const box=root.querySelector('.wc-preview-diagnostics'),items=preview&&Array.isArray(lines)?lines.filter(x=>typeof x==='string'):[];box.hidden=!items.length;box.querySelector('p').textContent=items.join('\n');}
 function clear(){showDiagnostics([]);form.elements.document.setCustomValidity('');clearTimeout(expiry);root.querySelector('.wc-code').textContent='';root.querySelector('.wc-room').textContent='';root.querySelector('.wc-greeting').textContent='';root.querySelector('.wc-options').replaceChildren();root.querySelector('.wc-file-name').textContent='';form.reset();generation++;busy=false;}
 function close(){clear();root.close();}
 function counter(selector,total,remaining=total){const element=root.querySelector(selector),left=Math.max(0,Math.min(total,remaining??total));element.textContent=left===0?'시도 횟수 초과 · 직원에게 확인해주세요.':left+'회 남음 · '+(selector==='.wc-reference-note'?'모두 틀리면 날짜 확인':total+'회 오류 시 확인 제한');element.setAttribute('aria-label',element.textContent);}
 function render(message=''){
  for(const section of root.querySelectorAll('[data-step]')){section.hidden=section.dataset.step!==stage;for(const input of section.querySelectorAll('input'))input.disabled=section.hidden||locked||input.dataset.rejected==='true';}
  const index=stage==='reference'?0:stage==='name'||stage==='dates'?1:2;root.querySelectorAll('.wc-progress span').forEach((x,i)=>x.classList.toggle('active',i===index));
  root.querySelectorAll('.wc-progress span')[1].textContent=mode==='document'?'2 날짜·이름':'2 숙박 날짜';root.querySelectorAll('.wc-progress span')[2].textContent=mode==='document'?'3 확정서 확인':'3 이름 선택';
  unknown.hidden=stage!=='reference'||locked;unknown.disabled=busy;
  next.textContent=stage==='upload'?'확정서 확인 →':stage==='choice'?'선택 확인 →':'다음 →';if(locked){next.textContent='확인 종료';const note=root.querySelector('[data-step="'+stage+'"] .wc-attempt');if(note){note.textContent='확인 제한 · 직원과 채팅해주세요.';note.setAttribute('aria-label',note.textContent);}}next.disabled=locked||busy;status.textContent=message;
 }
 function apply(result){
  showDiagnostics(result.preview_diagnostics);
  if(preview&&result.preview_day)root.querySelector('.wc-preview-day').textContent='확인 대상 체크인 날짜: '+result.preview_day;
  if(result.stage==='complete'){
   root.querySelector('.wc-result h3').textContent=result.property;root.querySelector('.wc-room').textContent=result.room;root.querySelector('.wc-code').textContent=result.access_code;root.querySelector('.wc-greeting').textContent=result.greeting;form.hidden=true;root.querySelector('.wc-result').hidden=false;root.scrollTop=0;
   expiry=setTimeout(close,300000);return;
  }
  stage=result.stage==='fallback_dates'?'dates':result.stage;mode=result.mode||mode;
  if(stage==='reference')counter('.wc-reference-note',3,result.reference_remaining);
  if(stage==='name')counter('.wc-name-note',3,result.name_remaining);
  if(stage==='upload'){const note=root.querySelector('[data-step=upload] .wc-attempt');note.textContent='1회 남음 · 실패 시 직원 확인';note.setAttribute('aria-label',note.textContent);}
  if(stage==='choice'){
   const list=root.querySelector('.wc-options');list.replaceChildren();for(const item of result.options||[]){const label=document.createElement('label'),input=document.createElement('input'),text=document.createElement('span');input.type='radio';input.name='choice_id';input.value=item.id;input.required=true;input.dataset.rejected=String((result.rejected_ids||[]).includes(item.id));text.textContent=item.label;label.append(input,text);list.append(label);}counter('.wc-choice-note',2,result.attempts_remaining);
  }
  render(result.message||'');root.scrollTop=0;
 }
 root.querySelector('.wc-close').onclick=close;root.querySelector('.wc-done').onclick=close;root.addEventListener('cancel',e=>{e.preventDefault();close();});root.querySelector('.wc-staff').onclick=()=>{close();chat?.();};window.addEventListener('pagehide',close);
 form.elements.document.onchange=()=>{const files=[...form.elements.document.files],error=files.length>2?'사진은 최대 2장까지 선택할 수 있습니다. 다시 선택해주세요.':'';form.elements.document.setCustomValidity(error);root.querySelector('.wc-file-name').textContent=error||(files.length?files.length+'장 선택 · '+files.map(f=>f.name).join(', '):'');if(error)status.textContent=error;else status.textContent='';};
 async function call(action,data,access_token){
  const r=await fetch(OMG_SUPABASE.url+'/functions/v1/beds24',{method:'POST',headers:{'Content-Type':'application/json',apikey:OMG_SUPABASE.publishableKey},body:JSON.stringify({action,data,...(access_token?{access_token}:{})}),signal:AbortSignal.timeout(data?.step==='upload'?90000:45000)}),result=await r.json();
  if(!r.ok||!result.ok){const e=Error(result.message||'직원과의 채팅으로 예약을 확인하여 주십시오.');e.code=result.code;if(action==='web_checkin_preview')e.previewDiagnostics=result.preview_diagnostics;throw e;}return result;
 }
 function verify(data){return preview?preview.request(data):call('web_checkin',data);}
 function rememberBlock(error){if(!preview&&error.code==='device_blocked')try{localStorage.setItem('wc-blocked:'+slug,'1');}catch{}}
 async function documentImage(file){
  if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>20*1024*1024)throw Error('20MB 이하의 JPG·PNG·WebP 캡처를 선택해주세요.');
  const bitmap=await createImageBitmap(file);try{if(!bitmap.width||!bitmap.height||bitmap.width*bitmap.height>50000000)throw Error('이미지가 너무 큽니다. 예약 정보 부분만 캡처해주세요.');const ratio=Math.min(1,2200/Math.max(bitmap.width,bitmap.height)),canvas=document.createElement('canvas');canvas.width=Math.round(bitmap.width*ratio);canvas.height=Math.round(bitmap.height*ratio);const ctx=canvas.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(bitmap,0,0,canvas.width,canvas.height);const image=canvas.toDataURL('image/jpeg',.88);canvas.width=canvas.height=0;if(image.length>2800000)throw Error('이미지가 너무 큽니다. 예약 정보 부분만 캡처해주세요.');return image;}finally{bitmap.close();}
 }
 async function submit(skip=false){
  if(locked||busy||(!skip&&!form.reportValidity())||skip&&stage!=='reference')return;busy=true;next.disabled=true;unknown.disabled=true;const current=generation;showDiagnostics([]);status.textContent=stage==='upload'?'예약확정서를 확인하고 있습니다…':'예약을 확인하고 있습니다…';
  try{const data={slug,verification_token:verificationToken,device_id:deviceId,step:skip?'unknown':stage,attempt_id:uuid()};
   if(stage==='reference')data.reference=form.elements.reference.value.trim();
   if(stage==='name')data.name=form.elements.name.value.trim();
   if(stage==='dates'){data.check_in=form.elements.check_in.value;data.check_out=form.elements.check_out.value;}
   if(stage==='choice')data.choice_id=root.querySelector('[name=choice_id]:checked')?.value;
   if(stage==='upload'){const files=[...form.elements.document.files];if(files.length<1||files.length>2)throw Error('사진을 1~2장 선택해주세요.');data.images=[];for(const file of files)data.images.push(await documentImage(file));}
   if(current!==generation)return;const result=await verify(data);if(current!==generation||!root.open)return;apply(result);
  }catch(error){if(current!==generation)return;
   if(error.code==='session_expired'){
    try{const result=await verify({slug,verification_token:verificationToken,device_id:deviceId,step:'resume'});if(current!==generation||!root.open)return;form.reset();apply(result);return;}catch(recovery){if(current!==generation)return;error=recovery;}
   }
   showDiagnostics(error.previewDiagnostics||[error.message]);
   if(['staff_required','device_blocked'].includes(error.code)){locked=true;rememberBlock(error);render(error.message);}else status.textContent=error.name==='TimeoutError'?'확인이 지연되고 있습니다. 잠시 후 다시 시도하거나 직원과 채팅해주세요.':error.message;}
  finally{if(current===generation){busy=false;next.disabled=locked;unknown.disabled=false;}}
 };
 form.onsubmit=event=>{event.preventDefault();submit();};unknown.onclick=()=>submit(true);
 async function open(value,onChat,previewFactory){clear();preview=previewFactory?previewFactory():null;slug=value;chat=onChat;stage='reference';mode='reference';locked=false;form.hidden=false;root.querySelector('.wc-result').hidden=true;root.querySelector('.wc-staff').hidden=!onChat&&!preview;
  root.querySelector('.wc-heading-note').textContent=preview?'모의화면 · TEST':'GUEST WEB CHECK-IN';root.querySelector('.wc-retry').hidden=!preview;root.querySelector('.wc-preview-tools').hidden=!preview;root.querySelector('.wc-preview-tools').open=false;root.querySelector('.wc-preview-info').textContent=preview?.info||'';root.querySelector('.wc-preview-day').textContent='';root.querySelector('.wc-retry').onclick=()=>open(value,onChat,previewFactory);
  root.querySelector('.wc-staff').onclick=()=>{if(preview){status.textContent='모의화면입니다. 실제 게스트는 직원과의 채팅으로 연결됩니다.';return;}close();chat?.();};
  root.querySelector('[data-step=upload] .wc-note').textContent='체크인·체크아웃 날짜와 예약자 이름 또는 예약번호가 보이게 캡처해주세요. 정보가 나뉘어 있으면 최대 2장을 함께 선택할 수 있습니다.';
  root.querySelector('[data-step=upload] .wc-note:last-child').textContent='확인에 필요한 이미지만 AI로 전송하며 OMS에 이미지 파일을 저장하지 않습니다.';
  if(preview){deviceId=uuid();verificationToken=uuid();}else try{deviceId=persistent(localStorage,'wc-device-id');verificationToken=persistent(sessionStorage,'wc-flow-token:'+slug);locked=localStorage.getItem('wc-blocked:'+slug)==='1';}catch{locked=true;}
  counter('.wc-reference-note',3);render(locked?'직원과의 채팅으로 예약을 확인하여 주십시오.':'');root.showModal();root.scrollTop=0;if(locked)return;
  const current=generation;busy=true;render('확인 중입니다…');try{const result=await verify({slug,verification_token:verificationToken,device_id:deviceId,step:'resume'});if(current===generation&&root.open)apply(result);}catch(error){if(current===generation){locked=['staff_required','device_blocked'].includes(error.code);rememberBlock(error);render(error.message);showDiagnostics(error.previewDiagnostics||[error.message]);}}finally{if(current===generation){busy=false;next.disabled=locked;unknown.disabled=false;if(!locked&&stage==='reference')form.elements.reference.focus();}}
 }
 return {call,open};
})();
