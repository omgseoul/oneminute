(async()=>{
 const G=GuestSupport,s=await omgSession.require({allowCompleted:true});if(!s)return;if(s.sessionKind!=='owner'){location.replace('app.html');return;}
 const auth={access_token:s.accessToken},call=(a,d={})=>G.call(a,d,auth);let state=await call('settings'),items=state.config.items.map(x=>({...x})),uploading=0;
 const form=document.getElementById('settings'),list=document.getElementById('items');form.hidden=false;
 document.getElementById('enabled').checked=state.config.enabled;document.getElementById('chatEnabled').checked=state.config.chat_enabled;
 function renderItems(){list.replaceChildren();items.forEach((item,index)=>{
  const el=document.createElement('div');el.className='item-editor';const asset=state.assets.find(a=>a.id===item.asset_id);
  el.innerHTML=`<div class="row"><label class="field grow">항목 ${index+1}<input maxlength="60" placeholder="예: 도어락 사용법" value="${G.esc(item.title)}" required></label><button type="button" class="btn danger small" aria-label="항목 삭제">삭제</button></div><div class="row"><span class="small grow">${asset?'첨부 완료 · '+(asset.mime==='application/pdf'?'PDF':'사진'):'사진 또는 PDF 첨부'}</span><label class="btn small">${asset?'첨부 변경':'파일 선택'}<input type="file" accept="image/*,application/pdf" hidden></label></div>`;
  el.querySelector('input[maxlength]').oninput=e=>item.title=e.target.value;
  el.querySelector('button').onclick=()=>{items.splice(index,1);renderItems();};
  if(asset){const preview=document.createElement('button');preview.type='button';preview.className='btn small';preview.textContent='보기';preview.onclick=()=>G.viewer(asset,item.title);el.lastChild.prepend(preview);}
  el.querySelector('input[type=file]').onchange=async e=>{const f=e.target.files[0];if(!f)return;uploading++;document.getElementById('save').disabled=true;G.message('파일을 올리고 있습니다…');try{const prepared=await G.photo(f),v=await G.call('upload',{},auth,prepared);item.asset_id=v.asset_id;state.assets.push(...v.assets);renderItems();G.message('첨부했습니다. 안내 설정 저장을 눌러주세요.');}catch(err){G.message(err.message,true);}finally{uploading--;document.getElementById('save').disabled=!!uploading;}};
  list.append(el);
 });}
 renderItems();document.getElementById('add').onclick=()=>{if(items.length>=20){G.message('안내 항목은 20개까지 가능합니다.',true);return;}items.push({title:'',asset_id:null});renderItems();list.lastChild.querySelector('input').focus();};
 form.onsubmit=async e=>{e.preventDefault();if(uploading)return;const btn=document.getElementById('save');btn.disabled=true;try{if(items.some(i=>!i.asset_id))throw new Error('각 안내 항목에 파일을 첨부해주세요.');await call('save_settings',{enabled:document.getElementById('enabled').checked,chat_enabled:document.getElementById('chatEnabled').checked,items});G.message('안내 설정을 저장했습니다.');}catch(err){G.message(err.message,true);}finally{btn.disabled=false;}};
 const url=new URL('guest.html',location.href);url.searchParams.set('p',state.config.slug);document.getElementById('url').value=url.href;document.getElementById('preview').href=url.href;
 if(typeof qrcode==='function'){const qr=qrcode(0,'M');qr.addData(url.href);qr.make();document.getElementById('qr').innerHTML=qr.createImgTag(5,20,'게스트 안내 QR');document.getElementById('download').onclick=()=>{const a=document.createElement('a');a.href=document.querySelector('#qr img').src;a.download='guest-support-qr.gif';a.click();};}else G.message('QR 생성기를 불러오지 못했습니다. 새로고침해주세요.',true);
 document.getElementById('copy').onclick=async()=>{try{await navigator.clipboard.writeText(url.href);G.message('주소를 복사했습니다.');}catch{document.getElementById('url').select();G.message('주소를 길게 눌러 복사해주세요.');}};
 G.message('');
})().catch(e=>GuestSupport.message(e.message,true));
