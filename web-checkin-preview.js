// Bind the test to the same verified login/property as the settings page.
window.WebCheckinPreview={open:(accessToken,propertyId,propertyName)=>{const loginPropertyId=window.omgSession?.get?.()?.propertyId;return WebCheckin.open('',null,()=>({
 info:(propertyName?propertyName+' · ':'')+'현재 지점에 연결된 실제 Beds24 예약으로 확인합니다. 운영 시간과 관계없이 테스트할 수 있으며 실제 게스트의 시도·차단 기록에는 영향을 주지 않습니다.',
 async request(data){
  const check=()=>{const s=window.omgSession?.get?.();if(window.omgSession?.get&&(s?.accessToken!==accessToken||s?.propertyId!==loginPropertyId))throw Error('로그인 지점이 변경되었습니다. 화면을 다시 열어주세요.');};
  check();const result=await WebCheckin.call('web_checkin_preview',{...data,property_id:propertyId},accessToken);check();
  if(propertyId&&result.property_id!==propertyId)throw Error('조회 지점이 일치하지 않습니다. 화면을 다시 열어주세요.');return result;
 }
}));}};
