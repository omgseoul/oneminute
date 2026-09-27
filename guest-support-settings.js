(async()=>{
 const G=GuestSupport,I=GuestIcons,s=await omgSession.require({allowCompleted:true});if(!s)return;if(s.sessionKind!=='owner'){location.replace('app.html');return;}
 const auth={access_token:s.accessToken},call=(a,d={})=>G.call(a,d,auth);let state=await call('settings'),items=state.config.items.map(x=>({...x})),uploading=0,selectedItem=null;
 const form=document.getElementById('settings'),list=document.getElementById('items'),picker=document.getElementById('iconPicker'),enabled=document.getElementById('enabled');form.hidden=false;
 enabled.checked=state.config.enabled;document.getElementById('chatEnabled').checked=state.config.chat_enabled;document.getElementById('chatIcon').innerHTML=I.svg('chat');
 enabled.onchange=()=>document.getElementById('enabledLabel').textContent=enabled.checked?'활성화':'비활성화';enabled.onchange();
 const closePicker=()=>{if(history.state?.qrIcons)history.back();else picker.close();};document.getElementById('closeIcons').onclick=closePicker;picker.addEventListener('cancel',e=>{e.preventDefault();closePicker();});window.addEventListener('popstate',()=>picker.open&&picker.close());
 function chooseIcon(id){if(selectedItem){selectedItem.icon=id;renderItems();}closePicker();}
 document.getElementById('noIcon').onclick=()=>chooseIcon(null);
 I.items.forEach(i=>{const b=document.createElement('button');b.type='button';b.className='icon-option';b.dataset.icon=i.id;b.innerHTML=I.svg(i.id)+'<small>'+i.id+'</small><span>'+G.esc(i.label)+'</span>';b.onclick=()=>chooseIcon(i.id);document.getElementById('iconOptions').append(b);});
 function renderItems(){list.replaceChildren();document.getElementById('itemCount').textContent=items.length+' / 9';document.getElementById('add').disabled=items.length>=9;
  items.forEach((item,index)=>{
   const el=document.createElement('section');el.className='item-editor';const asset=state.assets.find(a=>a.id===item.asset_id),icon=I.svg(item.icon);
   el.innerHTML=`<div class="row between"><b class="item-number">항목 ${index+1}</b><button type="button" class="delete-item" aria-label="항목 ${index+1} 삭제">삭제</button></div><label class="field">메뉴 이름 설정<input maxlength="60" placeholder="예: 도어락 사용법" value="${G.esc(item.title)}" required></label><div class="item-actions"><button type="button" class="btn select-icon">${icon}<span>이모지 설정</span></button><label class="btn attach-file">${asset?'변경':'결과 사진 첨부'}<input type="file" accept="image/*,application/pdf" hidden aria-label="결과 사진 첨부"></label></div>${asset?'<button type="button" class="asset-preview">첨부 '+(asset.mime==='application/pdf'?'PDF':'사진')+' 보기 <span>↗</span></button>':''}`;
   el.querySelector('input[maxlength]').oninput=e=>item.title=e.target.value;
   el.querySelector('.delete-item').onclick=()=>{items.splice(index,1);renderItems();};
   el.querySelector('.select-icon').onclick=()=>{selectedItem=item;document.querySelectorAll('.icon-option').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.icon===item.icon)));picker.showModal();history.pushState({...history.state,qrIcons:true},'');};
   if(asset)el.querySelector('.asset-preview').onclick=()=>G.viewer(asset,item.title);
   el.querySelector('input[type=file]').onchange=async e=>{const f=e.target.files[0];if(!f)return;uploading++;document.getElementById('save').disabled=true;G.message('파일을 올리고 있습니다…');try{const prepared=await G.photo(f),v=await G.call('upload',{},auth,prepared);item.asset_id=v.asset_id;state.assets.push(...v.assets);renderItems();G.message('첨부했습니다. 안내 설정 저장을 눌러주세요.');}catch(err){G.message(err.message,true);}finally{uploading--;document.getElementById('save').disabled=!!uploading;}};
   list.append(el);
  });
 }
 renderItems();document.getElementById('add').onclick=()=>{if(items.length>=9)return;items.push({title:'',asset_id:null,icon:null});renderItems();list.lastChild.querySelector('input').focus();};
 form.onsubmit=async e=>{e.preventDefault();if(uploading)return;const btn=document.getElementById('save');btn.disabled=true;try{if(items.some(i=>!i.asset_id))throw new Error('각 안내 항목에 파일을 첨부해주세요.');await call('save_settings',{enabled:enabled.checked,chat_enabled:document.getElementById('chatEnabled').checked,items});G.message('안내 설정을 저장했습니다.');}catch(err){G.message(err.message,true);}finally{btn.disabled=false;}};
 const url=new URL('guest.html',location.href);url.searchParams.set('p',state.config.slug);document.getElementById('url').value=url.href;document.getElementById('preview').href=url.href;
 if(typeof qrcode==='function'){
  const qr=qrcode(0,'M');qr.addData(url.href);qr.make();
  const count=qr.getModuleCount(),scale=12,margin=4,canvas=document.createElement('canvas');canvas.width=canvas.height=(count+margin*2)*scale;
  const ctx=canvas.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.fillStyle='#000';
  for(let y=0;y<count;y++)for(let x=0;x<count;x++)if(qr.isDark(y,x))ctx.fillRect((x+margin)*scale,(y+margin)*scale,scale,scale);
  const png=canvas.toDataURL('image/png'),img=new Image();img.src=png;img.alt='게스트 안내 QR';document.getElementById('qr').replaceChildren(img);
  const bytes=Uint8Array.from(atob(png.split(',')[1]),c=>c.charCodeAt(0)),file=new File([bytes],'guest-support-qr.png',{type:'image/png'});
  let downloadUrl=null,downloadExpires=0;
  const downloadButton=document.getElementById('download');
  const downloadStatus=document.createElement('p');downloadStatus.className='help';downloadStatus.setAttribute('role','status');downloadButton.closest('.row').after(downloadStatus);
  async function downloadThroughBrowser(){
   downloadStatus.textContent='QR 다운로드를 준비하고 있습니다…';
   if(!downloadUrl||Date.now()>downloadExpires){
    const uploaded=await G.call('upload',{},auth,file),asset=uploaded.assets?.find(a=>a.id===uploaded.asset_id);
    if(!asset?.url)throw new Error('QR 다운로드 주소를 만들지 못했습니다. 다시 눌러주세요.');
    const link=new URL(asset.url);link.searchParams.set('download',file.name);downloadUrl=link.href;downloadExpires=Date.now()+10*60*1000;
   }
   const link=document.createElement('a');link.href=downloadUrl;link.textContent='QR PNG 다운로드 다시 열기';link.className='btn wide';
   downloadStatus.replaceChildren(document.createTextNode('브라우저에서 QR 이미지를 저장해주세요. '),link);
   location.assign(downloadUrl);
  }
  downloadButton.onclick=async()=>{
   downloadButton.disabled=true;
   try{
    if(!window.OMGNative&&navigator.canShare?.({files:[file]})&&navigator.share){
     try{await navigator.share({files:[file],title:'게스트 접속 QR'});return;}catch(error){if(error.name==='AbortError')return;}
    }
    await downloadThroughBrowser();
   }catch(error){downloadStatus.textContent=error.message||'QR 저장에 실패했습니다. 다시 눌러주세요.';}
   finally{downloadButton.disabled=false;}
  };
 }else G.message('QR 생성기를 불러오지 못했습니다. 새로고침해주세요.',true);
 document.getElementById('copy').onclick=async()=>{try{await navigator.clipboard.writeText(url.href);G.message('주소를 복사했습니다.');}catch{document.getElementById('url').select();G.message('주소를 길게 눌러 복사해주세요.');}};
 G.message('');
})().catch(e=>GuestSupport.message(e.message,true));
