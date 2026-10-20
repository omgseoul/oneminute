/* Default OMS bot portrait; null in saved settings means this built-in image. */
window.OMSBotAvatar=(()=>{
 const butler={src:"bot-avatar-butler.webp?v=20261021-logo",name:"안경 쓴 시바견 집사"};
 // Preset photos are stored as data URIs. Only this exact former preset is upgraded.
 const previousButlerHash="2b0aa20a8914641500aacef2edd7587ed042d7654a60182f4cbf31f2895f4595";
 let butlerData;
 function butlerImage(){
  if(!butlerData)butlerData=(async()=>{
   const response=await fetch(butler.src,{cache:"force-cache"});if(!response.ok)throw Error("아바타를 불러오지 못했습니다.");
   const blob=await response.blob();return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error("아바타를 불러오지 못했습니다."));reader.readAsDataURL(blob);});
  })().catch(error=>{butlerData=null;throw error;});
  return butlerData;
 }
 async function upgrade(image){
  if(!image?.startsWith('data:image/webp;base64,')||!window.crypto?.subtle)return image;
  try{
   const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(image));
   const hash=Array.from(new Uint8Array(digest),n=>n.toString(16).padStart(2,'0')).join('');
   return hash===previousButlerHash?await butlerImage():image;
  }catch{return image;}
 }
 return {src:"bot-avatar-helper.webp?v=20261020",name:"OMS 시바견 도우미",butler,butlerImage,upgrade};
})();
