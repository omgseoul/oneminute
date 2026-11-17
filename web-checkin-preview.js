// The shared guest UI calls the authenticated, isolated preview state machine.
window.WebCheckinPreview={open:accessToken=>WebCheckin.open('',null,()=>({
 info:'현재 지점에 연결된 실제 Beds24 예약으로 확인합니다. 운영 시간과 관계없이 테스트할 수 있으며 실제 게스트의 시도·차단 기록에는 영향을 주지 않습니다.',
 request:data=>WebCheckin.call('web_checkin_preview',data,accessToken)
}))};
