window.OMSHomeCleaning=(()=>{
 const broom='<svg viewBox="0 0 32 32" fill="none" aria-hidden="true"><path d="m20 15 7-10a2 2 0 0 0-3-2l-7 11M12 13l10 7-9 10L3 23l9-10Z M9 20l-3 4m7-1-3 4m7-1-3 3" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 let pickerHost;
 function attachPicker(){pickerHost ||= document.getElementById('workingPropertyPicker');const label=document.querySelector('#workingGrid .working-property');if(label&&pickerHost?.children.length){label.replaceChildren(pickerHost);pickerHost.hidden=false;const name=pickerHost.querySelector('.property-picker-name');if(name)name.textContent=label.title;pickerHost.querySelector('.property-picker-extra')?.remove();}}
 function parkPicker(){pickerHost ||= document.getElementById('workingPropertyPicker');if(pickerHost){pickerHost.hidden=true;document.getElementById('workingSection').append(pickerHost);}}
 function render(host,properties,isOwner){
  const single=!isOwner&&properties.length===1,visible=properties.slice(0,5);
  const link=(p,index)=>{const d=p.days?.[index];if(!d)return '<span>—</span>';const label=['오늘','내일','모레'][index],url='online.html#cleaning?property='+encodeURIComponent(p.id)+'&day='+encodeURIComponent(d.day);return `<a href="${url}" class="home-cleaning-count ${index===0?'is-today':''}" aria-label="${esc(p.name+' '+label+' 청소 '+(d.count??'미연결')+'개 보기')}">${d.count??'—'}</a>`;};
  host.className='home-cleaning'+(single?' is-single':'');
  host.innerHTML=`<span class="home-cleaning-icon">${broom}</span>`+(single?`<div class="home-cleaning-inline">${['오늘','내일','모레'].map((name,i)=>`<span>${name} ${link(properties[0],i)}</span>`).join('<i aria-hidden="true">/</i>')}</div>`:`<div class="home-cleaning-scroll"><div class="home-cleaning-grid" style="--branches:${visible.length}"><span></span>${visible.map(p=>`<small title="${esc(p.name)}">${esc(Array.from(p.name).slice(0,3).join('').toLowerCase())}</small>`).join('')}${['오늘','내일'].map((name,i)=>`<strong>${name}</strong>${visible.map(p=>link(p,i)).join('')}`).join('')}</div></div>`)+(properties.length>5?'<a class="home-cleaning-more" href="online.html#cleaning" aria-label="청소관리 더 보기">more ›</a>':'');
  if(!properties.length)host.innerHTML='<span class="home-cleaning-icon">'+broom+'</span><span class="home-cleaning-note">표시할 청소 지점이 없습니다.</span>';
 }
 function mount(session,isOwner){const host=document.getElementById('homeCleaning'),cache=window.OMSHomeSnapshot;let revision=0,stopped=false;const saved=cache?.read('cleaningSummary',true);if(saved?.properties)render(host,saved.properties,isOwner);
  async function refresh(){if(stopped||document.hidden)return;const n=++revision;try{const {data,error}=await omgSupabase.rpc('home_cleaning_summary',{p_access_token:session.accessToken});if(error||!data?.ok)throw Error(error?.message||data?.message||'청소 일정을 불러오지 못했습니다.');if(n!==revision||stopped)return;render(host,data.properties||[],isOwner);host.title='체크아웃 기준 청소 개수';cache?.write('cleaningSummary',data,cache.day());}catch(e){host.title=e.message;if(!host.querySelector('a'))host.innerHTML='<span class="home-cleaning-note">청소 정보 연결을 확인해주세요.</span>';}}
  refresh();let timer=setInterval(refresh,60000);addEventListener('focus',refresh);document.addEventListener('visibilitychange',refresh);addEventListener('pagehide',()=>{stopped=true;revision++;clearInterval(timer);timer=null;});addEventListener('pageshow',()=>{stopped=false;if(!timer)timer=setInterval(refresh,60000);refresh();});
 }
 return{mount,render,attachPicker,parkPicker};
})();
