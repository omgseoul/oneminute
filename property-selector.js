(function(){
  const LABELS={attendance:"근태",missions:"미션",messages:"메세지",work_status:"근태",attendance_records:"근태"};
  let styleReady=false;
  function addStyle(){
    if(styleReady)return;
    styleReady=true;
    const style=document.createElement("style");
    style.textContent=`
      .property-picker{position:relative;margin-left:auto;z-index:12}
      .property-picker-button{display:flex;align-items:center;gap:7px;max-width:172px;height:38px;padding:0 12px;border:1px solid #d6e1ee;border-radius:13px;background:#fff;color:#183153;font:900 11px/1.2 inherit;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;box-shadow:0 5px 14px rgba(32,67,105,.07)}
      .property-picker-button:after{content:"⌄";color:#2467bd;font-size:14px}
      .property-picker.open-up .property-picker-button:after{content:"⌃"}
      .property-picker-panel{position:absolute;top:44px;right:0;width:min(250px,calc(100vw - 28px));max-height:min(360px,calc(100dvh - 32px));padding:8px;border:1px solid #dce6f2;border-radius:16px;background:#fff;box-shadow:0 16px 38px rgba(24,49,83,.18);overflow-y:auto;overscroll-behavior:contain}
      .property-picker.open-up .property-picker-panel{top:auto;bottom:44px}
      .property-picker-panel[hidden]{display:none}
      .property-picker-title{margin:3px 5px 7px;color:#7d8ca0;font-size:9px;font-weight:800}
      .property-picker-option{display:grid;grid-template-columns:minmax(0,1fr) auto auto;align-items:center;gap:7px;min-height:44px;padding:7px 9px;border-radius:12px;color:#314764;font-size:12px;font-weight:900}
      .property-picker-option:hover,.property-picker-option:has(input:checked){background:#edf5ff;color:#2467bd}
      .property-picker-option span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .property-picker-option input{grid-column:3;width:18px;height:18px;margin:0;accent-color:#2467bd}
      .property-picker-id{grid-column:2;color:#8795a6;font-size:9px;font-weight:700}
    `;
    document.head.append(style);
  }
  async function rpc(name,args){const{data,error}=await window.omgSupabase.rpc(name,args);if(error||!data?.ok)throw new Error(data?.message||"지점 목록을 불러오지 못했습니다.");return data;}
  function build({properties,permission,host,onChange,defaultSelection="all"}){
    addStyle();
    if(properties.length<2)return{properties,selectedIds:()=>properties.map(x=>x.property_id)};
    const own=properties.find(item=>item.is_own)||properties[0];
    const isChecked=item=>defaultSelection==="own"?item.property_id===own.property_id:true;
    const root=document.createElement("div");
    root.className="property-picker";
    root.innerHTML=`<button class="property-picker-button" type="button" aria-expanded="false">${defaultSelection==="own"?own.property_name:"All"}</button><div class="property-picker-panel" hidden><p class="property-picker-title">${LABELS[permission]||"지점"} · 복수 선택</p><label class="property-picker-option"><span>All</span><small class="property-picker-id">모든 지점</small><input data-all type="checkbox" ${defaultSelection==="all"?"checked":""}></label>${properties.map(item=>`<label class="property-picker-option"><span>${String(item.property_name).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[c])}</span><small class="property-picker-id">${item.is_own?"본지점":item.management_number??""}</small><input data-id="${item.property_id}" type="checkbox" ${isChecked(item)?"checked":""}></label>`).join("")}</div>`;
    host.classList.add("property-picker-mounted");
    host.append(root);
    const button=root.querySelector(".property-picker-button"),panel=root.querySelector(".property-picker-panel"),all=root.querySelector("[data-all]"),items=[...root.querySelectorAll("[data-id]")];
    const selectedIds=()=>items.filter(x=>x.checked).map(x=>x.dataset.id);
    function label(){const chosen=items.filter(x=>x.checked);button.textContent=chosen.length===items.length?"All":chosen.length===1?properties.find(x=>String(x.property_id)===String(chosen[0].dataset.id))?.property_name:`${chosen.length}개 지점`;all.checked=chosen.length===items.length;all.indeterminate=chosen.length>0&&chosen.length<items.length;}
    async function changed(){if(!selectedIds().length)items.find(x=>String(x.dataset.id)===String(own.property_id)).checked=true;label();await onChange?.(selectedIds(),properties);}
    function close(){panel.hidden=true;root.classList.remove("open-up");button.setAttribute("aria-expanded","false");}
    button.onclick=()=>{const opening=panel.hidden;document.querySelectorAll(".property-picker-panel:not([hidden])").forEach(open=>{if(open!==panel)open.hidden=true;});panel.hidden=!panel.hidden;if(opening){root.classList.remove("open-up");const buttonRect=button.getBoundingClientRect(),panelHeight=Math.min(panel.scrollHeight,360),spaceBelow=window.innerHeight-buttonRect.bottom-16,spaceAbove=buttonRect.top-16;if(spaceBelow<panelHeight&&spaceAbove>spaceBelow)root.classList.add("open-up");}else root.classList.remove("open-up");button.setAttribute("aria-expanded",String(!panel.hidden));};
    all.onchange=()=>{items.forEach(x=>x.checked=all.checked);if(!all.checked)items.find(x=>String(x.dataset.id)===String(own.property_id)).checked=true;changed();};
    items.forEach(x=>x.onchange=changed);
    document.addEventListener("click",event=>{if(!root.contains(event.target))close();});
    label();
    return{properties,selectedIds,root,close};
  }
  async function mount({accessToken,permission,host,onChange,defaultSelection="all"}){
    const data=await rpc("list_property_shares",{p_access_token:accessToken});
    const properties=(data.properties||[]).filter(item=>item.is_own||(item.permissions||[]).includes(permission));
    return build({properties,permission,host,onChange,defaultSelection});
  }
  function mountStatic({properties,permission,host,onChange,defaultSelection="own"}){
    return build({properties,permission,host,onChange,defaultSelection});
  }
  window.omgPropertySelector={mount,mountStatic};
})();
