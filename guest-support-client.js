(function(){
 const c=window.OMG_SUPABASE;
 window.GuestSupport={
  esc:s=>String(s??'').replace(/[&<>"']/g,x=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[x])),
  async call(action,data={},auth={},file){
   const payload={action,data,...auth};let body,headers={apikey:c.publishableKey};
   if(file){body=new FormData();body.set('request',JSON.stringify(payload));body.set('file',file);}
   else{headers['Content-Type']='application/json';body=JSON.stringify(payload);}
   let r;try{r=await fetch(c.url+'/functions/v1/guest-support',{method:'POST',headers,body,signal:AbortSignal.timeout(40000)});}catch{throw new Error('연결이 끊겼습니다. 입력한 내용은 남아 있습니다. 다시 시도해주세요.');}
   const v=await r.json();if(!r.ok||!v.ok)throw new Error(v.message||'요청에 실패했습니다. 다시 시도해주세요.');return v;
  },
  async photo(file){
   if(!file.type.startsWith('image/')){if(file.type==='application/pdf'&&file.size<=4194304)return file;throw new Error('사진 또는 4MB 이하 PDF를 선택해주세요.');}
   const image=await createImageBitmap(file);const ratio=Math.min(1,1600/Math.max(image.width,image.height));const canvas=document.createElement('canvas');canvas.width=Math.round(image.width*ratio);canvas.height=Math.round(image.height*ratio);canvas.getContext('2d').drawImage(image,0,0,canvas.width,canvas.height);image.close();
   const blob=await new Promise(r=>canvas.toBlob(r,'image/jpeg',.85));if(!blob||blob.size>4194304)throw new Error('더 작은 사진을 선택해주세요.');return new File([blob],'photo.jpg',{type:'image/jpeg'});
  },
  message(text,error=false){const el=document.getElementById('status');if(el){el.textContent=text;el.className='status'+(error?' error':'');}},
  viewer(asset,title='안내'){
   if(!asset)throw new Error('첨부파일을 확인하지 못했습니다. 다시 열어주세요.');
   const d=document.createElement('dialog');d.innerHTML='<div class="top"><b>'+this.esc(title)+'</b><button class="icon-btn" aria-label="닫기">×</button></div>';
   if(asset.mime==='application/pdf'){const a=document.createElement('a');a.className='btn primary wide';a.textContent='PDF 안내 열기';a.href=asset.url;a.target='_blank';a.rel='noopener';d.append(a);}
   else{const img=new Image();img.src=asset.url;img.className='file-preview';img.alt=title;d.append(img);}
   document.body.append(d);d.querySelector('button').onclick=()=>d.close();d.addEventListener('click',e=>{if(e.target===d)d.close();});d.addEventListener('close',()=>d.remove());d.showModal();
  }
 };
 document.addEventListener('pointerdown',e=>document.querySelectorAll('details[open]').forEach(d=>{if(!d.contains(e.target))d.open=false;}));
})();
