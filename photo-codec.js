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
 async function video(file){
  const maxSource=200*1024*1024,maxOutput=20*1024*1024,maxDuration=180;
  if(!file||(!file.type.startsWith('video/')&&!/\.(mp4|mov|m4v|webm|3gp|mkv)$/i.test(file.name||'')))throw new Error('사진이나 동영상 파일을 선택해주세요.');
  if(file.size>maxSource)throw new Error('원본 동영상은 200MB 이하로 선택해주세요.');
  if(typeof MediaRecorder==='undefined'||typeof HTMLCanvasElement.prototype.captureStream!=='function')throw new Error('이 기기에서는 동영상 압축을 지원하지 않습니다. 최신 Chrome에서 다시 시도해주세요.');
  const url=URL.createObjectURL(file),source=document.createElement('video');source.muted=true;source.playsInline=true;source.preload='metadata';source.src=url;
  try{
   await new Promise((resolve,reject)=>{source.onloadedmetadata=resolve;source.onerror=()=>reject(new Error('동영상을 열 수 없습니다. 다른 파일을 선택해주세요.'));});
   if(!Number.isFinite(source.duration)||source.duration<=0||source.duration>maxDuration)throw new Error('동영상은 3분 이하로 선택해주세요.');
   const width=source.videoWidth,height=source.videoHeight;if(!width||!height)throw new Error('동영상 화면을 읽지 못했습니다.');
   const scale=Math.min(1,1280/Math.max(width,height)),canvas=document.createElement('canvas');canvas.width=Math.max(2,Math.round(width*scale));canvas.height=Math.max(2,Math.round(height*scale));
   const ctx=canvas.getContext('2d');if(!ctx)throw new Error('동영상 압축을 시작하지 못했습니다.');
   const canvasStream=canvas.captureStream(24),sourceStream=source.captureStream?.()||source.mozCaptureStream?.(),tracks=[...canvasStream.getVideoTracks(),...(sourceStream?.getAudioTracks()||[])],stream=new MediaStream(tracks);
   const mime=['video/webm;codecs=vp9,opus','video/webm;codecs=vp8,opus','video/webm'].find(type=>MediaRecorder.isTypeSupported(type));if(!mime)throw new Error('이 기기에서 사용할 수 있는 동영상 압축 형식이 없습니다.');
   const audioRate=sourceStream?.getAudioTracks().length?64000:0,targetBits=Math.floor((maxOutput*8/source.duration)*.94),videoRate=Math.max(120000,Math.min(2500000,targetBits-audioRate));
   const recorder=new MediaRecorder(stream,{mimeType:mime,videoBitsPerSecond:videoRate,audioBitsPerSecond:audioRate||64000}),chunks=[];
   const result=new Promise((resolve,reject)=>{recorder.ondataavailable=event=>{if(event.data?.size)chunks.push(event.data);};recorder.onerror=()=>reject(new Error('동영상 압축 중 오류가 발생했습니다.'));recorder.onstop=()=>{const blob=new Blob(chunks,{type:recorder.mimeType||'video/webm'});if(blob.size>maxOutput){reject(new Error('동영상을 20MB 이하로 압축하지 못했습니다. 영상 길이를 줄여 다시 올려주세요.'));return;}if(!blob.size){reject(new Error('압축된 동영상이 비어 있습니다. 다시 선택해주세요.'));return;}resolve(new File([blob],'video.webm',{type:'video/webm',lastModified:Date.now()}));};});
   let frame=0;const draw=()=>{if(source.ended||source.paused)return;ctx.drawImage(source,0,0,canvas.width,canvas.height);frame=requestAnimationFrame(draw);};
   await source.play();ctx.drawImage(source,0,0,canvas.width,canvas.height);recorder.start(1000);frame=requestAnimationFrame(draw);
   await new Promise(resolve=>{source.onended=resolve;});if(recorder.state!=='inactive')recorder.stop();cancelAnimationFrame(frame);
   try{return await result;}finally{stream.getTracks().forEach(track=>track.stop());sourceStream?.getTracks().forEach(track=>track.stop());}
  }finally{URL.revokeObjectURL(url);source.removeAttribute('src');source.load();}
 }
 async function media(file){return file?.type?.startsWith('video/')||/\.(mp4|mov|m4v|webm|3gp|mkv)$/i.test(file?.name||'')?video(file):photo(file);}
 async function dataURL(file){const compressed=await media(file);return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('첨부 파일을 읽지 못했습니다.'));reader.readAsDataURL(compressed);});}
 root.OMGPhoto={photo,video,media,dataURL};
})(typeof window==='undefined'?globalThis:window);
