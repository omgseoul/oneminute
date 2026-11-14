window.HomeGuestCount=(()=>{
 const pending=new Map();
 // Read the same account-specific filters restored by the guest inbox.
 function preferences(session){
  const key=String(session.ownerId||session.employeeId||session.propertyId);
  let filters={},period={days:7,from:'',to:''};
  try{const v=JSON.parse(localStorage.getItem('oms-online-inbox-filters:'+key)||'null');if(v?.version===1)filters=v;}catch{}
  try{const v=JSON.parse(localStorage.getItem('oms-online-period:'+key)||'null');if(v&&Number.isInteger(v.days)&&v.days>=0&&v.days<=3650&&(v.days>0||/^\d{4}-\d{2}-\d{2}$/.test(v.from)&&/^\d{4}-\d{2}-\d{2}$/.test(v.to)&&v.to>=v.from))period=v;}catch{}
  let statuses=['new','confirmed','request','inquiry','qr'];
  if(Array.isArray(filters.statuses)){statuses=filters.statuses.filter(x=>['qr','new','confirmed','request','inquiry','cancelled','black','unknown'].includes(x));if(filters.qrVersion!==1&&!statuses.includes('qr'))statuses.push('qr');}
  return {filters,period,statuses};
 }
 function query(session){
  const {filters,period,statuses}=preferences(session);
  const stays=['checkin','staying','checkout','other'];
  const to=period.days?new Intl.DateTimeFormat('en-CA',{timeZone:session.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date()):period.to;
  const from=period.days?new Date(Date.parse(to+'T12:00:00Z')-(period.days-1)*86400000).toISOString().slice(0,10):period.from;
  return {statuses,direction:['all','guest','host'].includes(filters.direction)?filters.direction:'all',message_from:from,message_to:to,
   stay_types:Array.isArray(filters.stayTypes)&&filters.stayTypes.every(x=>stays.includes(x))?filters.stayTypes:stays,
   unread_only:filters.unreadOnly===true,unreplied_only:filters.unrepliedOnly===true,
   ...(Array.isArray(filters.properties)&&filters.properties.every(x=>typeof x==='string')?{properties:[...new Set(filters.properties)]}:{})};
 }
 function nativeQuery(session){
  const data=query(session),{period}=preferences(session);
  return {filters:{version:1,qrVersion:1,statuses:data.statuses,direction:data.direction,stayTypes:data.stay_types,unreadOnly:data.unread_only,unrepliedOnly:data.unreplied_only,...(data.properties?{properties:data.properties}:{})},period};
 }
 function syncNative(session){
  try{if(session?.accessToken)window.OMGNative?.setMessageBadgeQuery?.(session.accessToken,JSON.stringify(nativeQuery(session)));}catch{}
 }
 function summary(token,session=window.omgSession?.get?.()){
  if(!session)return Promise.reject(Error('로그인 정보를 확인해주세요.'));
  syncNative({...session,accessToken:token});
  const data=query(session),key=JSON.stringify([token,data]);if(pending.has(key))return pending.get(key);
  const work=(async()=>{const {data:result,error}=await omgSupabase.rpc('guest_message_summary',{p_access_token:token,p_data:{filters:{version:1,qrVersion:1,statuses:data.statuses,direction:data.direction,stayTypes:data.stay_types,unreadOnly:data.unread_only,unrepliedOnly:data.unreplied_only,...(data.properties?{properties:data.properties}:{})},period:{days:0,from:data.message_from,to:data.message_to}}});if(error||!result?.ok)throw Error('게스트 메시지 수를 불러오지 못했습니다.');return result;})().finally(()=>pending.delete(key));
  pending.set(key,work);return work;
 }
 return {query,nativeQuery,syncNative,summary,load:(token,session)=>summary(token,session).then(data=>Number(data.unread)||0)};
})();
