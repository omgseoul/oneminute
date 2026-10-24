(function(){
  let active=null,sequence=0;
  function normalize(value){const uid=String(value||'').replace(/[\s:-]/g,'').toUpperCase();if(!/^(?:[0-9A-F]{8}|[0-9A-F]{14}|[0-9A-F]{16}|[0-9A-F]{20})$/.test(uid))throw new Error('태그의 고유번호(UID)를 16진수로 입력해주세요.');return uid;}
  function scan({timeoutMs=60000}={}){
    active?.cancel();const id=`nfc-${Date.now()}-${++sequence}`;let resolve,reject,timer;
    const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
    const cleanup=()=>{clearTimeout(timer);window.removeEventListener('omg:nfc-result',receive);window.OMGNative?.stopAttendanceNfc?.(id);if(active?.id===id)active=null;};
    function receive(event){const result=event.detail;if(result?.request_id!==id)return;cleanup();try{if(result.error)throw new Error(result.error);resolve(normalize(result.uid));}catch(error){reject(error);}}
    const request={id,promise,cancel(){cleanup();reject(new Error('태그 읽기가 취소되었습니다.'));}};active=request;
    window.addEventListener('omg:nfc-result',receive);
    if(!window.OMGNative?.startAttendanceNfc){cleanup();reject(new Error('태그 읽기는 NFC를 지원하는 휴대폰의 최신 OMS 앱에서 사용할 수 있습니다.'));}
    else{if(timeoutMs>0)timer=setTimeout(()=>{cleanup();reject(new Error('태그를 읽지 못했습니다. NFC를 켜고 다시 시도해주세요.'));},timeoutMs);try{window.OMGNative.startAttendanceNfc(id);}catch(error){cleanup();reject(error);}}
    return request;
  }
  // Read NFC silently: attendance status belongs in the compact home progress bar.
  async function mountWorker(session,host,options={}){
    if(session.sessionKind!=='staff')return null;
    let state=null,pending=null,busy=false,paused=false,refreshing=null,retryTimer=null,revision=0,timer=null;
    const current=()=>!paused&&window.omgSession.get()?.accessToken===session.accessToken;
    async function rpc(uid){
      let timeout;
      try{
        const {data,error}=await Promise.race([
          window.omgSupabase.rpc('attendance_nfc_entry',{p_access_token:session.accessToken,p_tag_uid:uid||null}),
          new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('출근 상태를 확인하지 못했습니다. 연결을 확인하고 다시 시도해주세요.')),12000);})
        ]);
        if(error||!data?.ok)throw new Error(data?.message||'출근 상태를 확인하지 못했습니다. 연결을 확인하고 다시 시도해주세요.');return data;
      }finally{clearTimeout(timeout);}
    }
    function paint(){options.onChange?.(state);window.dispatchEvent(new CustomEvent('omg:attendance-entry',{detail:state}));}
    function canRead(){return current()&&!document.hidden&&state?.basis==='nfc'&&!state.entry_at&&!state.checkin_report_at&&state.status==='working'&&window.OMGNative?.startAttendanceNfc;}
    async function read(){
      if(busy||!canRead())return;busy=true;let received=false;
      try{pending=scan({timeoutMs:0});const uid=await pending.promise;received=true;if(!current())return;const result=await rpc(uid);if(current()){revision++;state=result;paint();}}
      catch(error){if(current()&&received){options.onError?.(error);retryTimer=setTimeout(read,1500);}}
      finally{pending=null;busy=false;}
    }
    async function refresh(){
      if(refreshing)return refreshing;
      const startedRevision=revision;
      refreshing=(async()=>{const result=await rpc();if(!current())return state;if(startedRevision===revision){state=result;paint();}read();return state;})().finally(()=>{refreshing=null;});
      return refreshing;
    }
    const startTimer=()=>{if(!timer)timer=setInterval(()=>{if(current()&&!document.hidden)refresh().catch(()=>{});},30000);};
    const resume=()=>{if(window.omgSession.get()?.accessToken!==session.accessToken)return;paused=false;startTimer();if(!document.hidden)refresh().catch(()=>{});};
    const suspend=()=>{paused=true;clearTimeout(retryTimer);clearInterval(timer);timer=null;pending?.cancel();};
    window.addEventListener('pagehide',suspend);
    window.addEventListener('pageshow',resume);
    window.addEventListener('focus',resume);
    document.addEventListener('visibilitychange',()=>{if(document.hidden)suspend();else resume();});
    startTimer();
    const controller={get state(){return state;},refresh,read,stop:suspend};
    try{await refresh();}catch(error){options.onLoadError?.(error);}
    return controller;
  }
  window.addEventListener('pagehide',()=>active?.cancel());
  window.OMSAttendanceNfc={normalize,scan,mountWorker};
})();
