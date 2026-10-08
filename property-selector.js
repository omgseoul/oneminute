(function(){
  const LABELS={property_settings:"숙소설정",account_settings:"계정 설정",attendance:"근태",missions:"To do",messages:"메세지",work_status:"근태",attendance_records:"근태"};
  let styleReady=false;
  function addStyle(){
    if(styleReady)return;
    styleReady=true;
    const style=document.createElement("style");
    style.textContent=`
      .property-picker{position:relative;margin-left:auto;z-index:12}
      .property-picker:has(.property-picker-panel:not([hidden])){z-index:19}
      .property-picker-button{display:flex;align-items:center;gap:7px;max-width:172px;height:34px;padding:0 12px;border:1px solid #d6e1ee;border-radius:12px;background:#fff;color:#183153;font-family:inherit;font-size:11px;font-weight:900;line-height:1.2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;box-shadow:0 5px 14px rgba(32,67,105,.07)}
      .property-picker-mounted .property-picker-button{max-width:min(164px,46vw);height:34px;font-weight:700}
      .property-picker-name{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .property-picker-extra{flex:none;white-space:nowrap}
      .property-picker-button:after{content:"⌄";flex:none;color:#2467bd;font-size:14px}
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
  function build({properties,permission,host,onChange,defaultSelection="all",alwaysShow=false,allLabel="All"}){
    addStyle();
    if(properties.length<2&&!alwaysShow)return{properties,selectedIds:()=>properties.map(x=>x.property_id)};
    const own=properties.find(item=>item.is_own)||properties[0];
    const isChecked=item=>defaultSelection==="own"?item.property_id===own.property_id:true;
    const root=document.createElement("div");
    root.className="property-picker";
    root.innerHTML=`<button class="property-picker-button" type="button" aria-expanded="false">${defaultSelection==="own"?own.property_name:allLabel}</button><div class="property-picker-panel" hidden><p class="property-picker-title">${LABELS[permission]||"지점"} · 복수 선택</p><label class="property-picker-option"><span>All</span><small class="property-picker-id">모든 지점</small><input data-all type="checkbox" ${defaultSelection==="all"?"checked":""}></label>${properties.map(item=>`<label class="property-picker-option"><span>${String(item.property_name).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[c])}</span><small class="property-picker-id">${item.is_own?"본지점":item.management_number??""}</small><input data-id="${item.property_id}" type="checkbox" ${isChecked(item)?"checked":""}></label>`).join("")}</div>`;
    host.classList.add("property-picker-mounted");
    host.append(root);
    const button=root.querySelector(".property-picker-button"),panel=root.querySelector(".property-picker-panel"),all=root.querySelector("[data-all]"),items=[...root.querySelectorAll("[data-id]")];
    const selectedIds=()=>items.filter(x=>x.checked).map(x=>x.dataset.id);
    function label(){
      const selected=new Set(items.filter(x=>x.checked).map(x=>String(x.dataset.id)));
      const chosen=properties.filter(x=>selected.has(String(x.property_id))).sort((a,b)=>{
        const first=Number(a.management_number),second=Number(b.management_number);
        return (Number.isFinite(first)&&first>0?first:Infinity)-(Number.isFinite(second)&&second>0?second:Infinity);
      });
      const isAll=chosen.length===items.length,name=isAll?allLabel:chosen[0]?.property_name||own.property_name,extra=isAll?0:Math.max(0,chosen.length-1);
      const nameNode=document.createElement("span");nameNode.className="property-picker-name";nameNode.textContent=name;
      button.replaceChildren(nameNode);
      if(extra){const extraNode=document.createElement("span");extraNode.className="property-picker-extra";extraNode.textContent=`+${extra}`;button.append(extraNode);}
      button.title=extra?`${name} +${extra}`:name;
      button.setAttribute("aria-label",extra?`${name} 외 ${extra}개 지점`:name);
      all.checked=isAll;all.indeterminate=chosen.length>0&&!isAll;
    }
    async function changed(){if(!selectedIds().length)items.find(x=>String(x.dataset.id)===String(own.property_id)).checked=true;label();await onChange?.(selectedIds(),properties);}
    function close(){panel.hidden=true;root.classList.remove("open-up");button.setAttribute("aria-expanded","false");}
    button.onclick=()=>{const opening=panel.hidden;document.querySelectorAll(".property-picker-panel:not([hidden])").forEach(open=>{if(open!==panel)open.hidden=true;});panel.hidden=!panel.hidden;if(opening){root.classList.remove("open-up");const buttonRect=button.getBoundingClientRect(),panelHeight=Math.min(panel.scrollHeight,360),spaceBelow=window.innerHeight-buttonRect.bottom-16,spaceAbove=buttonRect.top-16;if(spaceBelow<panelHeight&&spaceAbove>spaceBelow)root.classList.add("open-up");}else root.classList.remove("open-up");button.setAttribute("aria-expanded",String(!panel.hidden));};
    all.onchange=()=>{items.forEach(x=>x.checked=all.checked);if(!all.checked)items.find(x=>String(x.dataset.id)===String(own.property_id)).checked=true;changed();};
    items.forEach(x=>x.onchange=changed);
    document.addEventListener("click",event=>{if(!root.contains(event.target))close();});
    label();
    return{properties,selectedIds,root,close};
  }
  async function mount({accessToken,permission,host,onChange,defaultSelection="all",allLabel="All"}){
    const data=await rpc("list_property_shares",{p_access_token:accessToken});
    const properties=(data.properties||[]).filter(item=>item.is_own||(item.permissions||[]).includes(permission));
    return build({properties,permission,host,onChange,defaultSelection,allLabel});
  }
  function mountStatic({properties,permission,host,onChange,defaultSelection="own",alwaysShow=false,allLabel="All"}){
    return build({properties,permission,host,onChange,defaultSelection,alwaysShow,allLabel});
  }
  function mountSingle({items=[],host,onChange,value="",placeholder="선택",title="선택"}){
    addStyle();
    const escape=value=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[c]);
    let options=items,selected=String(value??"");
    const root=document.createElement("div");
    root.className="property-picker";
    host.replaceChildren(root);
    function close(){const panel=root.querySelector(".property-picker-panel"),button=root.querySelector(".property-picker-button");if(!panel||!button)return;panel.hidden=true;root.classList.remove("open-up");button.setAttribute("aria-expanded","false");}
    function render(){
      if(!options.some(item=>String(item.value)===selected))selected="";
      const current=options.find(item=>String(item.value)===selected);
      root.innerHTML=`<button class="property-picker-button" type="button" aria-expanded="false">${escape(selected?current?.label:placeholder)}</button><div class="property-picker-panel" hidden><p class="property-picker-title">${escape(title)} · 단일 선택</p>${options.map(item=>`<label class="property-picker-option"><span>${escape(item.label)}</span><small class="property-picker-id">${escape(item.meta||"")}</small><input type="radio" name="${escape(host.id||"single-picker")}" value="${escape(item.value)}" ${String(item.value)===selected?"checked":""}></label>`).join("")}</div>`;
      const button=root.querySelector(".property-picker-button"),panel=root.querySelector(".property-picker-panel");
      button.onclick=()=>{const opening=panel.hidden;document.querySelectorAll(".property-picker-panel:not([hidden])").forEach(open=>{if(open!==panel)open.hidden=true;});panel.hidden=!panel.hidden;if(opening){root.classList.remove("open-up");const buttonRect=button.getBoundingClientRect(),panelHeight=Math.min(panel.scrollHeight,360),spaceBelow=window.innerHeight-buttonRect.bottom-16,spaceAbove=buttonRect.top-16;if(spaceBelow<panelHeight&&spaceAbove>spaceBelow)root.classList.add("open-up");}else root.classList.remove("open-up");button.setAttribute("aria-expanded",String(!panel.hidden));};
      root.querySelectorAll("input[type=radio]").forEach(input=>input.onchange=()=>{selected=input.value;render();onChange?.(selected);});
    }
    const outside=event=>{if(!root.contains(event.target))close();};
    document.addEventListener("click",outside);
    render();
    return{value:()=>selected,setItems(nextItems,nextValue=selected){options=nextItems;selected=String(nextValue??"");render();},root,close,destroy(){document.removeEventListener("click",outside);}};
  }
  function mountMulti({items=[],host,onChange,title="선택",allLabel="전체",selectedValues=null}){
    addStyle();const initial=Array.isArray(selectedValues)?selectedValues:items.map(item=>item.value),selected=new Set(initial.map(String)),escape=value=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[c]);
    const root=document.createElement("div");root.className="property-picker";host.replaceChildren(root);root.innerHTML=`<button class="property-picker-button" type="button" aria-expanded="false"></button><div class="property-picker-panel" hidden><p class="property-picker-title">${escape(title)} · 복수 선택</p><label class="property-picker-option"><span>${escape(allLabel)}</span><input data-all type="checkbox" checked></label>${items.map(item=>`<label class="property-picker-option"><span>${escape(item.label)}</span><input data-value="${escape(item.value)}" type="checkbox" checked></label>`).join("")}</div>`;
    const button=root.querySelector("button"),panel=root.querySelector(".property-picker-panel"),all=root.querySelector("[data-all]"),boxes=[...root.querySelectorAll("[data-value]")];
    function update(){boxes.forEach(box=>box.checked=selected.has(box.dataset.value));all.checked=selected.size===items.length;all.indeterminate=selected.size>0&&selected.size<items.length;button.textContent=all.checked?allLabel:selected.size===1?items.find(item=>selected.has(String(item.value))).label:selected.size?`${selected.size}개 선택`:"선택 없음";}
    function close(){panel.hidden=true;button.setAttribute("aria-expanded","false");}
    button.onclick=()=>{document.querySelectorAll(".property-picker-panel:not([hidden])").forEach(open=>{if(open!==panel)open.hidden=true;});panel.hidden=!panel.hidden;button.setAttribute("aria-expanded",String(!panel.hidden));};
    const outside=event=>{if(!root.contains(event.target))close();};all.onchange=()=>{selected.clear();if(all.checked)items.forEach(item=>selected.add(String(item.value)));update();onChange?.([...selected]);};boxes.forEach(box=>box.onchange=()=>{box.checked?selected.add(box.dataset.value):selected.delete(box.dataset.value);update();onChange?.([...selected]);});document.addEventListener("click",outside);update();return{root,close,values:()=>[...selected],setValues(values,notify=true){selected.clear();(values||[]).map(String).filter(value=>items.some(item=>String(item.value)===value)).forEach(value=>selected.add(value));update();if(notify)onChange?.([...selected]);},destroy(){document.removeEventListener("click",outside);root.remove();}};
  }
  async function mountPropertySingle({accessToken,permission,host,onChange}){
    const data=await rpc("list_property_shares",{p_access_token:accessToken});
    const properties=(data.properties||[]).filter(item=>item.is_own||(item.permissions||[]).includes(permission));
    const own=properties.find(item=>item.is_own)||properties[0];
    const control=mountSingle({host,items:properties.map(item=>({value:item.property_id,label:item.property_name,meta:item.is_own?"본지점":String(item.management_number||"")})),value:own.property_id,title:"지점 선택",onChange});
    return {...control,properties};
  }
  window.omgPropertySelector={mount,mountStatic,mountSingle,mountMulti,mountPropertySingle};
})();
