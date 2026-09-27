(()=>{
 const G=GuestSupport,I=GuestIcons,slug=new URLSearchParams(location.search).get('p'),key='omg_guest_'+slug,entry=document.getElementById('entry'),form=document.getElementById('entryForm');
 const stored=(storage,k)=>{try{return JSON.parse(storage.getItem(k)||'null');}catch{return null;}};
 function closeEntry(){if(history.state?.guestEntry)history.back();else entry.close();}
 document.getElementById('closeEntry').onclick=closeEntry;
 entry.addEventListener('cancel',e=>{e.preventDefault();closeEntry();});
 window.addEventListener('popstate',()=>{if(entry.open)entry.close();});
 function openEntry(){entry.showModal();history.pushState({...history.state,guestEntry:true},'');}
 const room=document.getElementById('roomNumber'),unknown=document.getElementById('roomUnknown');
 unknown.onchange=()=>{room.disabled=unknown.checked;room.required=!unknown.checked;};
 form.elements.check_in.onchange=()=>{form.elements.check_out.min=form.elements.check_in.value;};
 function render(portal){
  document.getElementById('propertyName').textContent=portal.name;document.querySelector('.entry-property').textContent=portal.name;document.title=portal.name+' · 숙소 안내';
  const list=document.getElementById('guides'),menus=portal.items.map(item=>({...item}));
  if(portal.chat_enabled)menus.push({title:'직원과 채팅',icon:'chat',chat:true});
  const rows=Math.max(3,Math.ceil(menus.length/2)),full=Math.max(0,rows*2-menus.length);list.style.setProperty('--rows',rows);list.dataset.rows=rows;
  menus.forEach((item,index)=>{const b=document.createElement('button');b.type='button';b.className='portal-menu'+(index<full?' full':'')+(item.chat?' chat-menu':'');const icon=I.svg(item.icon);b.innerHTML=(icon?'<span class="menu-icon">'+icon+'</span>':'')+'<b>'+G.esc(item.title)+'</b><span class="menu-arrow" aria-hidden="true">›</span>';b.title=item.title;
   b.onclick=async()=>{if(item.chat){const previous=stored(localStorage,key);if(previous?.room_id&&previous.expires>Date.now()){location.href='guest-chat.html?p='+encodeURIComponent(slug);return;}openEntry();return;}
    b.disabled=true;try{const fresh=await G.call('portal',{slug});G.viewer(fresh.assets.find(a=>a.id===item.asset_id),item.title);}catch(e){G.message(e.message,true);}finally{b.disabled=false;}};list.append(b);
  });G.message(menus.length?'':'등록된 안내가 없습니다.');
 }
 G.call('portal',{slug}).then(render).catch(e=>G.message(e.message,true));
 form.onsubmit=async e=>{e.preventDefault();const btn=form.querySelector('button[type=submit]'),status=document.getElementById('entryStatus');btn.disabled=true;status.textContent='대화를 준비하고 있습니다…';try{
  let pending=stored(sessionStorage,key+'_pending');if(!pending)pending={new_token:crypto.randomUUID()};sessionStorage.setItem(key+'_pending',JSON.stringify(pending));
  const data={...Object.fromEntries(new FormData(form)),room_unknown:unknown.checked,room_number:unknown.checked?'':room.value.trim(),entry_version:2,slug,...pending};
  const result=await G.call('start',data);localStorage.setItem(key,JSON.stringify({guest_token:pending.new_token,room_id:result.room_id,expires:Math.min(Date.parse(data.check_out)+2*86400000,Date.now()+60*86400000)}));sessionStorage.removeItem(key+'_pending');location.href='guest-chat.html?p='+encodeURIComponent(slug);
 }catch(err){status.textContent=err.message;status.className='status error';btn.disabled=false;}};
})();
