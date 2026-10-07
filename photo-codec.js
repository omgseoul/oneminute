(function(root){
 'use strict';
 async function decode(file){
  if(typeof createImageBitmap==='function')try{return await createImageBitmap(file);}catch(_){}
  const url=URL.createObjectURL(file),img=new Image();
  try{await new Promise((resolve,reject)=>{img.onload=resolve;img.onerror=()=>reject(new Error('사진 형식을 확인해주세요. JPG·PNG·WEBP 사진을 선택해주세요.'));img.src=url;});return img;}
  finally{URL.revokeObjectURL(url);}
 }
 async function photo(file){
  if(!file||(!file.type.startsWith('image/')&&!/\.(jpe?g|png|webp|heic|heif)$/i.test(file.name||'')))throw new Error('사진을 선택해주세요.');
  const image=await decode(file),width=image.width||image.naturalWidth,height=image.height||image.naturalHeight;
  try{
   if(!width||!height)throw new Error('사진을 읽지 못했습니다. 다른 사진을 선택해주세요.');
   const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d'),targetBytes=700*1024,maxBytes=Math.round(1.5*1024*1024);
   let scale=Math.min(1,1920/Math.max(width,height)),blob;
   for(let pass=0;pass<7;pass++){
    canvas.width=Math.max(1,Math.round(width*scale));canvas.height=Math.max(1,Math.round(height*scale));
    ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(image,0,0,canvas.width,canvas.height);
    for(const quality of [.86,.78,.7,.62,.54]){
     blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',quality));
     if(!blob)throw new Error('사진 변환에 실패했습니다. 다시 선택해주세요.');
     if(blob.size<=targetBytes)return new File([blob],'photo.jpg',{type:'image/jpeg',lastModified:Date.now()});
    }
    scale*=.86;
   }
   if(blob.size>maxBytes)throw new Error('사진을 1.5MB 이하로 압축하지 못했습니다. 다른 사진을 선택해주세요.');
   return new File([blob],'photo.jpg',{type:'image/jpeg',lastModified:Date.now()});
  }finally{image.close?.();}
 }
 async function dataURL(file){const compressed=await photo(file);return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('사진을 읽지 못했습니다.'));reader.readAsDataURL(compressed);});}
 root.OMGPhoto={photo,dataURL};
})(typeof window==='undefined'?globalThis:window);
