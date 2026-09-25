(function(){
  let counter=0;
  const escape=value=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  function close(root){root.querySelector(".warning-target-panel").hidden=true;root.querySelector("button").setAttribute("aria-expanded","false");root.classList.remove("open-up");}
  function mount(root,employees,rule={}){
    const selected=new Set(rule.employee_ids?.length?rule.employee_ids:rule.employee_id?[rule.employee_id]:[]);
    let all=!!rule.target_all;
    const id="warning-target-panel-"+(++counter);
    root.innerHTML=`<button type="button" class="warning-target-trigger" aria-expanded="false" aria-controls="${id}"><span></span><b aria-hidden="true">⌄</b></button><div class="warning-target-panel" id="${id}" hidden><p>근로자 · 복수 선택</p><label><span>All <small>자지점 전체</small></span><input type="checkbox" data-all></label>${employees.map(e=>`<label><span>${escape(e.display_name)}</span><input type="checkbox" data-id="${escape(e.employee_id)}"></label>`).join("")}</div>`;
    const button=root.querySelector("button"),panel=root.querySelector(".warning-target-panel"),allInput=root.querySelector("[data-all]");
    function sync(){
      const chosen=employees.filter(e=>selected.has(e.employee_id));
      button.querySelector("span").textContent=all?"All · 전체":!chosen.length?"근로자 선택":chosen.length===1?chosen[0].display_name:`${chosen[0].display_name} 외 ${chosen.length-1}명`;
      allInput.checked=all;allInput.indeterminate=!all&&chosen.length>0;
      root.querySelectorAll("[data-id]").forEach(input=>input.checked=all||selected.has(input.dataset.id));
    }
    allInput.onchange=()=>{all=allInput.checked;selected.clear();sync();};
    root.querySelectorAll("[data-id]").forEach(input=>input.onchange=()=>{
      if(all){employees.forEach(e=>selected.add(e.employee_id));all=false;}
      input.checked?selected.add(input.dataset.id):selected.delete(input.dataset.id);sync();
    });
    button.onclick=()=>{
      const opening=panel.hidden;
      document.querySelectorAll(".warning-targets").forEach(close);
      if(opening){panel.hidden=false;button.setAttribute("aria-expanded","true");
        const rect=button.getBoundingClientRect();root.classList.toggle("open-up",window.innerHeight-rect.bottom<Math.min(panel.scrollHeight,300)&&rect.top>window.innerHeight-rect.bottom);}
    };
    root.warningTargets=()=>({employee_ids:all?[]:[...selected],target_all:all});
    sync();
  }
  document.addEventListener("pointerdown",event=>{document.querySelectorAll(".warning-targets").forEach(root=>{if(!root.contains(event.target))close(root);});});
  document.addEventListener("keydown",event=>{if(event.key==="Escape")document.querySelectorAll(".warning-targets").forEach(close);});
  window.omgWarningTargets={mount};
})();
