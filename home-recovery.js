/* Loading is bounded; server failures must not masquerade as a staff account. */
(function(){
 const failures=new Map();let timer;
 function box(){let node=document.getElementById('homeServiceStatus');if(!node){node=document.createElement('div');node.id='homeServiceStatus';node.setAttribute('role','status');node.hidden=true;document.getElementById('mainMenu').before(node);}return node;}
 function paint(){const node=box();node.replaceChildren();node.hidden=!failures.size;if(node.hidden)return;
  const text=document.createElement('span');text.textContent=[...failures.values()].join(' · ');node.append(text);
  const button=document.createElement('button');button.type='button';button.textContent='다시 시도';button.onclick=()=>location.reload();node.append(button);
 }
 function fail(area,error){const stamp=window.OMSHomeSnapshot?.updatedAt?.(({메시지:'messageCount',일정:'today',청소:'cleaningSummary'})[area]);const last=stamp?' (최근 조회 '+new Date(stamp).toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit'})+')':'';const restricted=error?.status===402||/exceed_.*quota|service.*restrict/i.test(error?.message||'');failures.set(area,restricted?'서버 이용 한도 제한으로 정보를 불러올 수 없습니다.':area+' 정보를 불러오지 못했습니다.'+last);const ids=({일정:['todayOverviewItems'],청소:['homeCleaning'],근무자:['workingGrid']})[area]||[];for(const id of ids){const el=document.getElementById(id);if(el&&/불러오는 중/.test(el.textContent))el.textContent=area+' 정보를 불러오지 못했습니다.';}paint();}
 function ok(area){failures.delete(area);paint();}
 async function bounded(work,ms=15000){let timeout;try{return await Promise.race([Promise.resolve(work),new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('응답 시간 초과')),ms);})]);}finally{clearTimeout(timeout);}}
 function start(){document.getElementById('mainMenu').style.visibility='hidden';timer=setTimeout(()=>fatal(new Error('응답 시간 초과')),16000);}
 function ready(){clearTimeout(timer);document.getElementById('mainMenu').style.visibility='';document.getElementById('mainMenu').style.display='';ok('로그인');}
 function fatal(error){clearTimeout(timer);document.getElementById('mainMenu').style.display='none';fail('로그인',error);for(const [id,value] of [['todayOverviewItems','일정을 불러오지 못했습니다.'],['homeCleaning','청소 정보를 불러오지 못했습니다.'],['workingGrid','근무자 정보를 불러오지 못했습니다.']]){const node=document.getElementById(id);if(node&&/불러오|불러오는/.test(node.textContent)){node.replaceChildren();const span=document.createElement('span');span.className='home-cleaning-note';span.textContent=value;node.append(span);}}document.getElementById('appShell').classList.add('ready');window.omgTransition?.ready();}
 window.OMSHomeRecovery={bounded,fail,ok,start,ready,fatal};
})();
