(function(){
 // Fragment tokens never appear in HTTP request URLs or referrers.
 window.openGuestEmailLink=async function(){
  const fragment=new URLSearchParams(location.hash.slice(1));
  if(!fragment.has('reply'))return;
  const token=fragment.get('reply');
  if(!/^[a-f0-9]{64}$/.test(token||''))throw new Error('유효하지 않은 답변 링크입니다. 이메일의 답변하기 버튼을 다시 눌러주세요.');
  const c=window.OMG_SUPABASE;
  const response=await fetch(c.url+'/functions/v1/guest-email/open',{
   method:'POST',headers:{'Content-Type':'application/json',apikey:c.publishableKey},
   body:JSON.stringify({token}),signal:AbortSignal.timeout(20000)
  });
  const session=await response.json();
  if(!response.ok||!session.ok)throw new Error(session.message||'대화방을 열지 못했습니다. 잠시 후 다시 눌러주세요.');
  const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if(!uuid.test(session.slug)||!uuid.test(session.room_id)||!uuid.test(session.guest_token)||!Number.isFinite(session.expires)||session.expires<=Date.now())throw new Error('대화 이용 시간이 만료되었습니다.');
  localStorage.setItem('omg_guest_'+session.slug,JSON.stringify({guest_token:session.guest_token,room_id:session.room_id,expires:session.expires}));
  history.replaceState(null,'',location.pathname+'?p='+encodeURIComponent(session.slug));
 };
})();
