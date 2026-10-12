(() => {
 'use strict';
 fetch('downloads/oms-update.json',{cache:'no-store'}).then(r=>r.ok?r.json():null).then(info=>{
  if(!info||!Number.isSafeInteger(info.version_code)||info.version_code<1)return;
  const url=new URL(info.apk_url,location.href);if(url.origin!==location.origin||!url.pathname.startsWith('/downloads/')||!url.pathname.endsWith('.apk'))return;
  url.searchParams.set('v',info.version_code);
  document.querySelectorAll('a[data-apk-download]').forEach(a=>{a.href=url.href;a.dataset.version=info.version_name;});
 }).catch(()=>{});
 const button=document.querySelector('[data-check-app-update]');if(button){button.hidden=typeof window.OMGNative?.checkForUpdate!=='function';button.onclick=()=>window.OMGNative.checkForUpdate();}
})();
