(() => {
 'use strict';
 const $=id=>document.getElementById(id),form=$('accountForm'),message=$('message'),submit=$('submitButton');
 const requestedSignup=new URLSearchParams(location.search).get('mode')==='signup';
 let mode=requestedSignup?'signup':'login';
 function setMode(next){
  mode=next;const signup=mode==='signup';
  $('loginTab').classList.toggle('on',!signup);$('signupTab').classList.toggle('on',signup);
  for(const [box,id] of [['nameBox','name'],['propertyBox','propertyName'],['confirmBox','confirmPassword'],['trialCodeBox','trialCode']]){$(box).hidden=!signup;$(id).required=signup;$(id).disabled=!signup;}
  $('password').autocomplete=signup?'new-password':'current-password';
  submit.textContent=signup?'가입하기':'계정 로그인';document.title=signup?'OMS 가입하기':'OMS 계정 로그인';
  message.textContent='';message.className='message';
 }
 $('loginTab').onclick=()=>setMode('login');$('signupTab').onclick=()=>setMode('signup');
 setMode(mode);
 form.addEventListener('submit',async event=>{
  event.preventDefault();message.textContent='';message.className='message';submit.disabled=true;
  const email=$('email').value.trim(),password=$('password').value;
  try{
   if(mode==='signup'){
    const name=$('name').value.trim(),propertyName=$('propertyName').value.trim(),code=$('trialCode').value.trim();
    if(!name||!propertyName||!code)throw Error('이름·사업장명·체험코드를 입력해주세요.');
    if(password!==$('confirmPassword').value)throw Error('비밀번호가 서로 다릅니다.');
    submit.textContent='체험코드 확인 중…';
    const checked=await omgSupabase.rpc('check_trial_code',{p_code:code});
    if(checked.error||!checked.data?.ok)throw Error(checked.data?.message||'체험코드를 확인하지 못했습니다. 잠시 후 다시 시도해주세요.');
    submit.textContent='가입 중…';
    const {data,error}=await omgSupabase.auth.signUp({email,password,options:{data:{name,property_name:propertyName,trial_code:code}}});
    if(error)throw Error(/Database error saving new user/i.test(error.message)?'가입을 완료하지 못했습니다. 체험코드가 이미 사용되었거나 사용할 수 없는 상태일 수 있습니다. 코드를 확인 후 다시 시도해주세요.':error.message);
    if(!data.user||data.user.identities?.length===0)throw Error('이미 가입된 이메일입니다. 로그인하거나 다른 이메일을 사용해주세요.');
    if(!data.session){
     const terms=checked.data;setMode('login');message.className='message ok';
     message.textContent=`체험코드가 확인되어 가입되었습니다. ${terms.trial_days}일 체험 · 저장 용량 ${(terms.storage_limit_bytes/1073741824).toFixed(2)}GB. 가입 확인 메일을 확인한 뒤 로그인해주세요.`;return;
    }
    location.replace('login.html?joined=1');
   }else{
    const {error}=await omgSupabase.auth.signInWithPassword({email,password});if(error)throw error;location.replace('login.html');
   }
  }catch(error){message.textContent=error.message==='Invalid login credentials'?'이메일 또는 비밀번호를 확인해주세요.':error.message||'계정 처리를 완료하지 못했습니다.';}
  finally{submit.disabled=false;submit.textContent=mode==='signup'?'가입하기':'계정 로그인';}
 });
 (async()=>{
  if(!requestedSignup&&await omgAccount.get()){location.replace('login.html');return;}
  $('accountShell').classList.add('ready');window.omgTransition?.ready();
 })().catch(()=>{$('accountShell').classList.add('ready');window.omgTransition?.ready();});
})();
