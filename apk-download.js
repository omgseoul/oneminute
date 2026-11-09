(() => {
 'use strict';
 const label=document.getElementById('appVersion'),button=document.getElementById('appVersionUpdate');
 let installed=null,busy=false;
 const valid=info=>info&&Number.isSafeInteger(info.version_code)&&info.version_code>0&&/^\d+(?:\.\d+){2}$/.test(info.version_name);
 const showVersion=info=>{if(label)label.textContent='Ver '+info.version_name.replace(/^0\./,'');};
 try{const info=JSON.parse(window.OMGNative?.getAppInfo?.()||'null');if(valid(info)){installed=info;showVersion(info);}}catch{}
 if(button)button.onclick=()=>{if(!button.hidden&&typeof window.OMGNative?.checkForUpdate==='function')window.OMGNative.checkForUpdate();};
 async function refresh(){
  if(busy||document.hidden)return;busy=true;
  try{
   const response=await fetch('downloads/oms-update.json',{cache:'no-store'});const info=response.ok?await response.json():null;
   if(!valid(info))return;
   const url=new URL(info.apk_url,location.href);if(url.origin!==location.origin||!url.pathname.startsWith('/downloads/')||!url.pathname.endsWith('.apk'))return;
   url.searchParams.set('v',info.version_code);
   document.querySelectorAll('a[data-apk-download]').forEach(a=>{a.href=url.href;a.dataset.version=info.version_name;a.download='OMS-'+info.version_name+'.apk';});
   document.querySelectorAll('[data-apk-version]').forEach(node=>node.textContent=info.version_name);
   // A browser shows the published version; an Android app always shows its installed version.
   if(!window.OMGNative)showVersion(info);
   if(button)button.hidden=!(installed&&info.version_code>installed.version_code&&typeof window.OMGNative?.checkForUpdate==='function');
  }catch{}finally{busy=false;}
 }
 refresh();
 if(label){document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});window.addEventListener('pageshow',refresh);}
})();
