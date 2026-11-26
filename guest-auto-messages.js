(async()=>{
 'use strict';
 const $=id=>document.getElementById(id),session=await omgSession.require({allowCompleted:true});if(!session)return;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const languages={common:'공통',ja:'일본어',en:'영어','zh-CN':'중국어 간체','zh-TW':'중국어 번체',ko:'한국어',fr:'프랑스어',de:'독일어',es:'스페인어',it:'이탈리아어',pt:'포르투갈어',ru:'러시아어',th:'태국어',vi:'베트남어',id:'인도네시아어'};
 const timing={booking:'예약시',booking_after:'예약 후',checkin_before:'체크인 전',checkin_after:'체크인 후'};
 let property=session.propertyId,branches=[],rules=[],logs=[],picker,busy=false,pending=null,languageTarget=null;
 const drafts=new Map(),dirty=new Set();
 function status(message,error=false){$('autoState').textContent=message;$('autoState').classList.toggle('error',error);}
 function lock(value){busy=value;$('addAutoMessage').disabled=value;$('autoProperty').inert=value;$('autoList').inert=value;$('autoTitleForm').querySelectorAll('button,input').forEach(x=>x.disabled=value);}
 async function call(action,data={},p=property){const r=await fetch(OMG_SUPABASE.url+'/functions/v1/beds24',{method:'POST',headers:{apikey:OMG_SUPABASE.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({action:'auto_message_'+action,access_token:session.accessToken,data:{...data,property_id:p}}),signal:AbortSignal.timeout(25000)});const v=await r.json();if(!r.ok||!v.ok)throw Error(v.message||'자동메시지를 불러오지 못했습니다.');return v;}
 function timingLabel(r){return timing[r.trigger]+(r.trigger==='booking'?'':` ${r.days}일`)+(r.trigger!=='booking'?` · ${r.send_time.slice(0,5)}`:'');}
 function populate(v){property=v.property_id;branches=v.branches;rules=v.rules;logs=v.logs;drafts.clear();dirty.clear();render();renderLogs();
  if(!picker)picker=omgPropertySelector.mountSingle({host:$('autoProperty'),title:'자동메시지 지점',items:branches.map(p=>({value:p.id,label:p.name})),value:property,onChange:changeProperty});
  else picker.setItems(branches.map(p=>({value:p.id,label:p.name})),property);
 }
 async function changeProperty(id){if(busy||id===property)return;if(dirty.size&&!confirm('작성 중인 내용이 있습니다. 저장하지 않고 지점을 바꿀까요?')){picker.setItems(branches.map(p=>({value:p.id,label:p.name})),property);return;}
  lock(true);status('지점 설정을 불러오는 중…');try{populate(await call('list',{},id));status('');}catch(e){picker.setItems(branches.map(p=>({value:p.id,label:p.name})),property);status(e.message,true);}finally{lock(false);}}
 function render(){
  $('autoList').innerHTML=rules.length?rules.map(r=>`<details class="auto-card" data-rule="${esc(r.id)}"><summary><span class="auto-copy"><strong>${esc(r.title)}</strong><small>${esc(timingLabel(r))} · ${Object.keys(r.messages).map(k=>languages[k]).join(' · ')}</small></span><span class="auto-status ${r.enabled?'on':''}">${r.enabled?'사용 중':'중지'}</span><span class="auto-chevron" aria-hidden="true">⌄</span></summary><div class="auto-editor"></div></details>`).join(''):'<div class="auto-empty"><strong>등록된 자동메시지가 없습니다.</strong>위의 <b>＋ 자동메시지 추가</b>를 눌러<br>첫 안내 메시지를 만들어보세요.</div>';
  $('autoList').querySelectorAll('details').forEach(card=>card.addEventListener('toggle',()=>{if(!card.open)return;const others=[...dirty].filter(id=>id!==card.dataset.rule);if(others.length&&!confirm('작성 중인 내용을 저장하지 않고 다른 메시지를 열까요?')){card.open=false;return;}others.forEach(id=>{dirty.delete(id);drafts.delete(id);});$('autoList').querySelectorAll('details').forEach(other=>{if(other!==card){other.open=false;if(others.includes(other.dataset.rule)){if(other.dataset.new)other.remove();else other.querySelector('.auto-editor').replaceChildren();}}});if(!drafts.has(card.dataset.rule)){const r=rules.find(x=>x.id===card.dataset.rule);drafts.set(r.id,{...structuredClone(r),active:'common'});editor(card);}}));
 }
 function editor(card){
  const d=drafts.get(card.dataset.rule),el=card.querySelector('.auto-editor');
  el.innerHTML=`<form><label class="auto-enable"><input type="checkbox" name="enabled" ${d.enabled?'checked':''}>자동 발송 사용 <small>· 저장 후 적용</small></label><label>발송 시기</label><div class="auto-timing"><select name="trigger" aria-label="발송 시기">${Object.entries(timing).map(([k,v])=>`<option value="${k}" ${d.trigger===k?'selected':''}>${v}</option>`).join('')}</select><div class="auto-stepper" ${d.trigger==='booking'?'hidden':''}><button type="button" data-step="-1" aria-label="일수 줄이기">−</button><input name="days" type="number" min="${d.trigger==='booking_after'?1:0}" max="365" step="1" inputmode="numeric" value="${d.days}" aria-label="발송 간격 일수" required><span>일</span><button type="button" data-step="1" aria-label="일수 늘리기">＋</button></div></div><div class="auto-clock" ${d.trigger!=='booking'?'':'hidden'}><span>발송 시간 · 숙소 현지 시간</span><input type="time" name="send_time" aria-label="발송 시간" value="${d.send_time.slice(0,5)}" required></div><p class="auto-timing-help"></p><h3 class="auto-content-title">발송 내용</h3><div class="auto-tabs" role="tablist" aria-label="메시지 언어"></div><div class="auto-compose"><textarea name="body" maxlength="4000" aria-label="공통 메시지" placeholder="안녕하세요 {{이름}}님.\n체크인 안내를 입력해주세요." required></textarea><div class="auto-variables" aria-label="게스트 정보 삽입">${['이름','체크인','체크아웃','비밀번호','객실'].map(k=>`<button type="button" data-variable="${k}">${k}</button>`).join('')}</div></div><div class="auto-content-footer"><small class="auto-count"></small><button type="button" class="auto-add-language">＋ 언어 추가</button></div><button type="button" class="auto-remove-language" hidden>이 언어 삭제</button><p class="auto-timing-help">국가 정보가 없거나 해당 언어 내용이 없으면 공통으로 발송합니다.</p><button type="submit" class="primary auto-submit">입력 완료</button></form>`;
  const form=el.querySelector('form'),body=form.elements.body;
  function remember(){d.messages[d.active]=body.value;dirty.add(d.id);counter();}
  function counter(){el.querySelector('.auto-count').textContent=`${body.value.length.toLocaleString()} / 4,000`+(d.active==='common'?' · 기본 발송':'');}
  function tabs(){el.querySelector('.auto-tabs').innerHTML=Object.keys(d.messages).map(k=>`<button type="button" role="tab" data-language="${k}" aria-selected="${d.active===k}">${languages[k]}</button>`).join('');body.value=d.messages[d.active]||'';body.setAttribute('aria-label',languages[d.active]+' 메시지');el.querySelector('.auto-remove-language').hidden=d.active==='common';counter();el.querySelectorAll('[data-language]').forEach(b=>b.onclick=()=>{remember();d.active=b.dataset.language;tabs();});}
  function setTiming(){const kind=form.elements.trigger.value;d.trigger=kind;el.querySelector('.auto-stepper').hidden=kind==='booking';el.querySelector('.auto-clock').hidden=kind==='booking';form.elements.days.min=kind==='booking_after'?'1':'0';if(kind==='booking_after'&&Number(form.elements.days.value)<1)form.elements.days.value=1;el.querySelector('.auto-timing-help').textContent=kind==='booking'?'새 예약이 연동되면 발송합니다.':kind==='booking_after'?'예약일에서 입력한 일수 뒤, 지정한 시간에 발송합니다.':kind==='checkin_before'?'지정한 시점 이후 접수된 당일·임박 예약은 예약 확인 후 발송하고 봇으로 알립니다.':'체크인 날짜를 기준으로 지정한 시간에 발송합니다.';}
  body.addEventListener('input',remember);form.addEventListener('change',()=>{dirty.add(d.id);setTiming();});
  el.querySelectorAll('[data-step]').forEach(b=>b.onclick=()=>{form.elements.days.value=Math.max(Number(form.elements.days.min),Math.min(365,(Number(form.elements.days.value)||0)+Number(b.dataset.step)));dirty.add(d.id);});
  el.querySelectorAll('[data-variable]').forEach(b=>b.onclick=()=>{body.setRangeText('{{'+b.dataset.variable+'}}',body.selectionStart,body.selectionEnd,'end');body.focus();remember();});
  el.querySelector('.auto-add-language').onclick=()=>{remember();languageTarget={d,card};$('autoLanguage').innerHTML=Object.entries(languages).filter(([k])=>!Object.hasOwn(d.messages,k)).map(([k,v])=>`<option value="${k}">${v}</option>`).join('');if($('autoLanguage').options.length)$('autoLanguageDialog').showModal();};
  el.querySelector('.auto-remove-language').onclick=()=>{if(confirm(languages[d.active]+' 내용을 삭제할까요?')){delete d.messages[d.active];d.active='common';dirty.add(d.id);tabs();}};
  form.onsubmit=e=>{e.preventDefault();remember();
   const blank=Object.keys(d.messages).find(k=>!d.messages[k].trim());if(blank){d.active=blank;tabs();body.setCustomValidity(languages[blank]+' 내용을 입력해주세요.');body.reportValidity();body.setCustomValidity('');return;}
   const unsupported=Object.values(d.messages).some(text=>[...text.matchAll(/\{\{([^{}]+)\}\}/g)].some(m=>!['이름','체크인','체크아웃','비밀번호','객실'].includes(m[1])));if(unsupported){status('자동 입력 요소는 오른쪽 버튼으로 넣어주세요.',true);return;}
   pending={id:d.id,revision:d.revision,trigger:form.elements.trigger.value,days:form.elements.trigger.value==='booking'?0:Number(form.elements.days.value),send_time:form.elements.send_time.value,messages:{...d.messages},enabled:form.elements.enabled.checked};
   $('autoTitle').value=d.title||'';$('titleState').textContent='';$('autoTitleDialog').showModal();$('autoTitle').focus();
  };
  tabs();setTiming();
 }
 $('addAutoMessage').onclick=()=>{if(busy)return;const existing=$('autoList').querySelector('[data-new]');if(existing){existing.open=true;existing.scrollIntoView({behavior:'smooth',block:'start'});return;}
  if(dirty.size&&!confirm('작성 중인 내용을 저장하지 않고 새 메시지를 만들까요?'))return;drafts.clear();dirty.clear();render();$('autoList').querySelector('.auto-empty')?.remove();$('autoList').querySelectorAll('details').forEach(x=>x.open=false);
  const id=crypto.randomUUID();drafts.set(id,{id,title:'',revision:0,trigger:'checkin_before',days:1,send_time:'09:00',enabled:true,messages:{common:''},active:'common'});dirty.add(id);
  const card=document.createElement('details');card.className='auto-card';card.dataset.rule=id;card.dataset.new='true';card.open=true;card.innerHTML='<summary><span class="auto-copy"><strong>새 자동메시지</strong><small>내용을 입력한 뒤 제목을 정해주세요.</small></span><span class="auto-chevron">⌄</span></summary><div class="auto-editor"></div>';$('autoList').prepend(card);editor(card);card.scrollIntoView({behavior:'smooth',block:'start'});
 };
 $('autoTitleForm').onsubmit=async e=>{e.preventDefault();if(busy||!pending)return;const title=$('autoTitle').value.trim();if(!title)return;
  lock(true);$('titleState').textContent='저장 중…';try{populate(await call('save',{...pending,title}));$('autoTitleDialog').close();pending=null;status('자동메시지 설정을 저장했습니다.');}catch(err){$('titleState').textContent=err.message;}finally{lock(false);}};
 $('cancelAutoTitle').onclick=()=>{$('autoTitleDialog').close();pending=null;};
 $('cancelAutoLanguage').onclick=()=>$('autoLanguageDialog').close();
 $('autoLanguageForm').onsubmit=e=>{e.preventDefault();const {d,card}=languageTarget,k=$('autoLanguage').value;d.messages[k]='';d.active=k;dirty.add(d.id);
  const f=card.querySelector('form');d.trigger=f.elements.trigger.value;d.days=Number(f.elements.days.value);d.send_time=f.elements.send_time.value;d.enabled=f.elements.enabled.checked;editor(card);$('autoLanguageDialog').close();card.querySelector('textarea').focus();};
 const statusNames={waiting:'대기',preparing:'확인 중',sending:'발송 중',sent:'발송 완료',failed:'발송실패',uncertain:'결과 확인 필요',skipped:'발송 제외'};
 let retryBusy=false;
 async function retryLogs(targets){if(retryBusy||!targets.length)return;retryBusy=true;lock(true);renderLogs();try{
  const v=await call('retry',{targets});logs=v.logs;status(v.retry_queued?`${v.retry_queued}명의 재전송을 접수했습니다. 결과는 발송 기록과 실패 알림에서 확인해주세요.`:v.retry_results?.[0]?.message||'재전송할 실패 건이 없습니다.',!v.retry_queued);
 }catch(e){status(e.message,true);}finally{retryBusy=false;lock(false);renderLogs();}}
 function renderLogs(){
  const eligible=logs.some(l=>l.can_retry);
  $('autoLogList').innerHTML=(eligible?`<div class="auto-retry-toolbar"><span>재전송할 게스트를 선택하세요.</span><button type="button" id="retrySelected" disabled>선택 재전송</button></div>`:'')+(logs.length?logs.map(l=>`<div class="auto-log"><strong>${esc(l.title)} · ${l.status==='sent'&&l.late_booking?'예외 발송 완료':statusNames[l.status]||esc(l.status)}</strong><div class="auto-log-guest">${l.can_retry?`<input type="checkbox" data-retry-select="${esc(l.id)}" aria-label="${esc(l.guest_name||'게스트')} 예약 ${esc(l.booking_id)} 재전송 선택" ${retryBusy?'disabled':''}>`:''}<span><b>${esc(l.guest_name||'이름 미등록')}</b> · 객실 ${esc(l.room_name||'미정')}<br>${l.channel?esc(l.channel)+' · ':''}예약 #${esc(l.booking_id)}${l.booking_reference?' · '+esc(l.booking_reference):''}<br>${esc(l.arrival||'체크인 미정')} ~ ${esc(l.departure||'체크아웃 미정')}</span>${l.can_retry?`<button type="button" data-retry="${esc(l.id)}" ${retryBusy?'disabled':''}>재전송</button>`:''}</div><small>${esc(new Date(l.updated_at).toLocaleString('ko-KR'))}${l.retry_count?' · 재전송 '+Number(l.retry_count)+'회':''}${l.error?' · '+esc(l.error):''}</small></div>`).join(''):'<p class="note">아직 발송 기록이 없습니다.</p>');
  const target=l=>({id:l.id,retry_count:l.retry_count||0});
  $('autoLogList').querySelectorAll('[data-retry]').forEach(b=>b.onclick=()=>retryLogs([target(logs.find(l=>l.id===b.dataset.retry))]));
  const selected=()=>[...$('autoLogList').querySelectorAll('[data-retry-select]:checked')].map(b=>target(logs.find(l=>l.id===b.dataset.retrySelect)));
  $('autoLogList').querySelectorAll('[data-retry-select]').forEach(b=>b.onchange=()=>{$('retrySelected').disabled=retryBusy||!selected().length;$('retrySelected').textContent=selected().length?`선택 ${selected().length}명 재전송`:'선택 재전송';});
  if($('retrySelected'))$('retrySelected').onclick=()=>retryLogs(selected());
 }
 $('showAutoLogs').onclick=()=>{$('autoLogs').hidden=!$('autoLogs').hidden;if(!$('autoLogs').hidden)$('autoLogs').scrollIntoView({behavior:'smooth',block:'nearest'});};
 $('refreshAutoLogs').onclick=async()=>{try{logs=(await call('list')).logs;renderLogs();}catch(e){status(e.message,true);}};
 window.addEventListener('beforeunload',e=>{if(dirty.size){e.preventDefault();e.returnValue='';}});
 if(session.sessionKind!=='owner'){status('자동메시지는 관리자 계정에서 설정할 수 있습니다.',true);return;}
 try{populate(await call('list'));const requested=new URLSearchParams(location.search).get('property');if(requested&&requested!==property&&branches.some(p=>p.id===requested))populate(await call('list',{},requested));if(new URLSearchParams(location.search).get('logs')==='1')$('autoLogs').hidden=false;status('');$('addAutoMessage').disabled=false;$('showAutoLogs').disabled=false;}catch(e){status(e.message,true);}
})();
