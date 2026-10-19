(() => {
 'use strict';
 fetch('downloads/oms-update.json',{cache:'no-store'}).then(r=>r.ok?r.json():null).then(info=>{
  if(!info||!Number.isSafeInteger(info.version_code)||info.version_code<1||!/^\d+(?:\.\d+){2}$/.test(info.version_name))return;
  const url=new URL(info.apk_url,location.href);if(url.origin!==location.origin||!url.pathname.startsWith('/downloads/')||!url.pathname.endsWith('.apk'))return;
  url.searchParams.set('v',info.version_code);
  document.querySelectorAll('a[data-apk-download]').forEach(a=>{a.href=url.href;a.dataset.version=info.version_name;a.download='OMS-'+info.version_name+'.apk';});
  document.querySelectorAll('[data-apk-version]').forEach(label=>label.textContent=info.version_name);
 }).catch(()=>{});
 const button=document.querySelector('[data-check-app-update]');if(button){button.hidden=typeof window.OMGNative?.checkForUpdate!=='function';button.style.display=button.hidden?'none':'block';button.onclick=()=>window.OMGNative.checkForUpdate();}
})();
