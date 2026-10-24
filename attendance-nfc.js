(function(){
  let active=null,sequence=0;
  function normalize(value){const uid=String(value||'').replace(/[\s:-]/g,'').toUpperCase();if(!/^(?:[0-9A-F]{8}|[0-9A-F]{14}|[0-9A-F]{16}|[0-9A-F]{20})$/.test(uid))throw new Error('태그의 고유번호(UID)를 16진수로 입력해주세요.');return uid;}
  function scan(){
    active?.cancel();const id=`nfc-${Date.now()}-${++sequence}`;let resolve,reject,timer;
    const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
    const cleanup=()=>{clearTimeout(timer);window.removeEventListener('omg:nfc-result',receive);window.OMGNative?.stopAttendanceNfc?.(id);if(active?.id===id)active=null;};
    function receive(event){const result=event.detail;if(result?.request_id!==id)return;cleanup();try{if(result.error)throw new Error(result.error);resolve(normalize(result.uid));}catch(error){reject(error);}}
    const request={id,promise,cancel(){cleanup();reject(new Error('태그 읽기가 취소되었습니다.'));}};active=request;
    window.addEventListener('omg:nfc-result',receive);
    if(!window.OMGNative?.startAttendanceNfc){cleanup();reject(new Error('태그 읽기는 NFC를 지원하는 휴대폰의 최신 OMS 앱에서 사용할 수 있습니다.'));}
    else{timer=setTimeout(()=>{cleanup();reject(new Error('태그를 읽지 못했습니다. NFC를 켜고 다시 시도해주세요.'));},60000);try{window.OMGNative.startAttendanceNfc(id);}catch(error){cleanup();reject(error);}}
    return request;
  }
  async function mountWorker(session,host){
    if(!host||session.sessionKind!=='staff')return;
    let state=null,disposed=false,pending=null,busy=false;
    const card=document.createElement('section');card.className='attendance-nfc-worker';card.hidden=true;
    const label=document.createElement('div'),button=document.createElement('button');button.type='button';button.textContent='NFC 태그하기';label.setAttribute('role','status');card.append(label,button);host.append(card);
    const current=()=>!disposed&&window.omgSession.get()?.accessToken===session.accessToken;
    const time=value=>new Date(value).toLocaleString('ko-KR',{timeZone:session.timezone||'Asia/Seoul'});
    async function rpc(uid){const {data,error}=await window.omgSupabase.rpc('attendance_nfc_entry',{p_access_token:session.accessToken,p_tag_uid:uid||null});if(error||!data?.ok)throw new Error(data?.message||'입장 기록을 확인하지 못했습니다. 연결을 확인하고 다시 시도해주세요.');return data;}
    function paint(){card.hidden=state.basis!=='nfc';if(card.hidden)return;label.textContent=state.entry_at?`입장 확인 · ${time(state.entry_at)}${state.checkin_report_at?'':' · 출근보고 미완료'}`:'현장 NFC 태그를 대면 입장이 기록됩니다.';button.hidden=!!state.entry_at||state.status!=='working';window.dispatchEvent(new CustomEvent('omg:attendance-entry',{detail:state}));}
    async function read(){if(busy||!current())return;busy=true;button.disabled=true;label.textContent='휴대폰 뒷면에 현장 NFC 태그를 대주세요.';try{pending=scan();const uid=await pending.promise;if(!current())return;label.textContent='입장 기록을 저장하고 있습니다…';const result=await rpc(uid);if(!current())return;state=result;paint();}catch(error){if(current())label.textContent=error.message;}finally{pending=null;busy=false;button.disabled=false;}}
    button.onclick=read;
    async function refresh(){try{state=await rpc();if(!current())return;paint();if(state.basis==='nfc'&&!state.entry_at&&state.status==='working'&&window.OMGNative?.startAttendanceNfc)read();}catch(error){if(current()){card.hidden=false;label.textContent=error.message;button.textContent='다시 확인';button.onclick=()=>{button.textContent='NFC 태그하기';button.onclick=read;refresh();};}}}
    window.addEventListener('pagehide',()=>{disposed=true;pending?.cancel();},{once:true});
    await refresh();return {get state(){return state;}};
  }
  window.addEventListener('pagehide',()=>active?.cancel());
  window.OMSAttendanceNfc={normalize,scan,mountWorker};
})();
