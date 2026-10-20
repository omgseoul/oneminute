/* One mission source and completion/date rules for To do, home and calendar. */
(function(){
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function complete(item,employeeId=''){
    if(item.owner_completed_at)return true;
    if(item.completion_mode==='any')return Number(item.completed_count)>0;
    if(employeeId)return (item.completion_employee_ids||item.completions?.map(x=>x.employee_id)||[]).includes(employeeId);
    return Number(item.target_count)>0&&Number(item.completed_count)>=Number(item.target_count);
  }
  function pending(items,employeeId=''){
    return items.filter(item=>item.active!==false&&(!employeeId||!item.target_employee_ids?.length||item.target_employee_ids.includes(employeeId))&&!complete(item,employeeId));
  }
  function dateKey(value=Date.now(),timezone='Asia/Seoul'){
    const parts=new Intl.DateTimeFormat('en-US',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(value));
    const p=Object.fromEntries(parts.map(x=>[x.type,x.value]));return `${p.year}-${p.month}-${p.day}`;
  }
  function section(item,{employeeId='',timezone='Asia/Seoul',now=Date.now()}={}){
    if(complete(item,employeeId))return 'completed';
    if(!item.due_at)return ['today','this_week','anytime'].includes(item.timing)?item.timing:'anytime';
    const due=dateKey(item.due_at,timezone),today=dateKey(now,timezone);
    if(due<today)return 'overdue';if(due===today)return 'today';
    const week=new Date(today+'T12:00:00Z');week.setUTCDate(week.getUTCDate()+7);
    return due<=week.toISOString().slice(0,10)?'this_week':'anytime';
  }
  async function load(session,{isOwner=session.sessionKind==='owner',propertyIds}={}){
    const rpc=async(name,args)=>{const {data,error}=await window.omgSupabase.rpc(name,{p_access_token:session.accessToken,...args});if(error||!data?.ok)throw new Error(data?.message||error?.message||'할 일을 불러오지 못했습니다.');return data;};
    if(!isOwner)return rpc('list_missions');
    if(propertyIds===undefined){
      const shares=await rpc('list_property_shares');
      propertyIds=(shares.properties||[]).filter(x=>x.is_own||(x.permissions||[]).includes('missions')).map(x=>x.property_id);
    }
    return rpc('list_shared_missions',{p_property_ids:propertyIds?.length?propertyIds:null});
  }
  function propertyTag(item,ownPropertyId){
    if(!item.property_name||item.is_own_property===true||!(item.is_own_property===false||(ownPropertyId&&item.property_id&&item.property_id!==ownPropertyId)))return '';
    const name=String(item.property_name).trim(),chars=typeof Intl.Segmenter==='function'?[...new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(name)].map(x=>x.segment):Array.from(name);
    const lines=[chars.slice(0,5).join('')];if(chars.length>5)lines.push(chars.slice(5,chars.length>10?8:10).join('')+(chars.length>10?'..':''));
    return `<small class="oms-mission-property" title="${escape(name)}" aria-label="타지점 ${escape(name)}">${lines.map(line=>`<b>${escape(line)}</b>`).join('')}</small>`;
  }
  window.OMSMissionTasks={complete,pending,dateKey,section,load,propertyTag};
  window.OMSWorkerTasks={events(items,employeeId){return items.filter(item=>(item.target_employee_ids||[]).includes(employeeId)||item.can_edit&&!item.holiday_request_id);},pending(items,employeeId){return pending(items,employeeId).filter(item=>!item.completed_at);}};
})();
