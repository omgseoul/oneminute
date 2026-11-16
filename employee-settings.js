window.EmployeeSettings=(()=>{
 let version=0,context=null;
 function closeMenus(except){document.querySelectorAll('.employee-menu:not([hidden])').forEach(menu=>{if(except?.contains(menu))return;menu.hidden=true;menu.closest('.employee-menu-wrap')?.querySelector('.employee-menu-toggle')?.setAttribute('aria-expanded','false');});}
 document.addEventListener('pointerdown',event=>closeMenus(event.target.closest('.employee-menu-wrap')));
 document.addEventListener('click',event=>closeMenus(event.target.closest('.employee-menu-wrap')));
 document.addEventListener('keydown',event=>{if(event.key==='Escape')closeMenus();});
 document.addEventListener('click',event=>{
  const button=event.target.closest('[data-help-toggle]');if(!button)return;
  const content=document.getElementById(button.getAttribute('aria-controls'));if(!content)return;
  content.hidden=!content.hidden;button.setAttribute('aria-expanded',String(!content.hidden));
 });
 async function call(token,property,enabled=null){const{data,error}=await omgSupabase.rpc('employee_profile_warning_config',{p_access_token:token,p_property_id:property,p_enabled:enabled});if(error||!data?.ok)throw new Error(error?.message||data?.message||'근무자 정보 설정을 불러오지 못했습니다.');return data;}
 async function load(token,property){
  const current=++version,box=document.getElementById('profileWarningEnabled'),status=document.getElementById('profileWarningStatus'),button=document.getElementById('profileWarningSave');
  context=null;box.disabled=true;button.disabled=true;status.textContent='불러오는 중…';
  try{const data=await call(token,property);if(current!==version)return;box.checked=data.enabled;context={token,property};status.textContent='';box.disabled=false;button.disabled=false;}
  catch(error){if(current===version)status.textContent=error.message;}
 }
 async function save(){
  if(!context)throw new Error('근무자 정보 설정을 먼저 불러와주세요.');
  const current=version,{token,property}=context,box=document.getElementById('profileWarningEnabled'),button=document.getElementById('profileWarningSave'),status=document.getElementById('profileWarningStatus');
  button.disabled=true;box.disabled=true;
  try{await call(token,property,box.checked);if(current===version)status.textContent='저장되었습니다.';}
  finally{if(current===version){button.disabled=false;box.disabled=false;}}
 }
 document.getElementById('profileWarningSave')?.addEventListener('click',()=>save().catch(error=>document.getElementById('profileWarningStatus').textContent=error.message));
 return{load,save};
})();
