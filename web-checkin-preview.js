// Local-only fixtures. This transport never calls Beds24, AI, or a production reset API.
window.WebCheckinPreview=(()=>{
 function create(){
  const day=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul'}).format(new Date());
  const checkout=new Date(Date.parse(day+'T00:00:00Z')+2*86400000).toISOString().slice(0,10);
  const booking={reference:'TEST123456',name:'홍길동',check_in:day,check_out:checkout};
  let stage='reference',mode='reference',referenceRemaining=3,nameRemaining=3,dateRemaining=2,choiceRemaining=2,blocked=false;
  const rejected=[],names=['김민지','이서준','박지우','최유진','정하늘','강도윤','조수빈','윤서연','장현우',booking.name];
  const options=names.map((label,i)=>({id:'preview-'+i,label}));
  for(let i=options.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[options[i],options[j]]=[options[j],options[i]];}
  const state=(message='')=>({ok:true,stage,mode,reference_remaining:referenceRemaining,name_remaining:nameRemaining,date_remaining:dateRemaining,attempts_remaining:choiceRemaining,options,rejected_ids:[...rejected],message});
  const fail=code=>{blocked=true;const e=Error('직원과의 채팅으로 예약을 확인하여 주십시오.');e.code=code;throw e;};
  const complete=()=>{stage='complete';return{ok:true,stage,property:'테스트 숙소 · 모의 정보',room:'TEST 201',access_code:'TEST-0000',greeting:'홍길동님, 반갑습니다! 아래는 실제 출입에 사용할 수 없는 모의 정보입니다.'};};
  const normalize=s=>String(s||'').normalize('NFKD').replace(/[\s\p{P}\p{M}]/gu,'').toLowerCase();
  function similarity(a,b){a=normalize(a);b=normalize(b);if(!a||!b)return 0;let row=Array.from({length:b.length+1},(_,i)=>i);for(let i=1;i<=a.length;i++){const next=[i];for(let j=1;j<=b.length;j++)next[j]=Math.min(next[j-1]+1,row[j]+1,row[j-1]+(a[i-1]===b[j-1]?0:1));row=next;}return 1-row[b.length]/Math.max(a.length,b.length);}
  return{info:`예약번호: ${booking.reference}\n예약자: ${booking.name}\n체크인: ${day}\n체크아웃: ${checkout}\n한국 날짜 기준의 가상 예약입니다. 운영 시간·실제 Beds24 연동은 검사하지 않습니다.`,async request(data){
   if(blocked)return fail('device_blocked');
   if(data.step==='resume')return state();
   if(stage==='reference'){
    if(data.step==='unknown'){stage='fallback_dates';mode='document';return state();}
    if(data.step!=='reference')throw Error('예약번호부터 확인해주세요.');
    if(similarity(data.reference,booking.reference)>=.9){stage='dates';return state();}
    if(--referenceRemaining===0){stage='fallback_dates';mode='document';return state('예약번호가 확인되지 않습니다. 숙박날짜로 확인해주세요.');}
    return state('예약번호가 확인되지 않습니다. 다시 확인해주세요.');
   }
   if((stage==='dates'||stage==='fallback_dates')&&data.step==='dates'){
    if(data.check_in!==booking.check_in||data.check_out!==booking.check_out){if(--dateRemaining===0)return fail('staff_required');return state('체크인·체크아웃 날짜를 확인해주세요.');}
    stage=mode==='document'?'name':'choice';return state();
   }
   if(stage==='name'&&data.step==='name'){
    if(similarity(data.name,booking.name)>.9){stage='upload';return state();}
    if(--nameRemaining===0)return fail('device_blocked');
    return state('예약명단에 없습니다. 이름을 확인해주세요.');
   }
   if(stage==='choice'&&data.step==='choice'){
    if(data.choice_id==='preview-9')return complete();
    if(!options.some(x=>x.id===data.choice_id)||rejected.includes(data.choice_id))return state('다른 이름을 선택해주세요.');
    rejected.push(data.choice_id);if(--choiceRemaining===0)return fail('staff_required');return state('예약자 이름을 다시 확인해주세요.');
   }
   if(stage==='upload'&&data.step==='upload'){if(data.document_outcome==='failure')return fail('staff_required');return complete();}
   throw Error('현재 확인 단계에서 다시 시도해주세요.');
  }};
 }
 return{open:()=>WebCheckin.open('',null,create)};
})();
