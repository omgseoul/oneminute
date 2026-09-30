(function(root){
  'use strict';
  function summarize(items){
    const days=new Map();let total=0;
    for(const item of items){
      const key=`${item.property_id||''}:${item.employee_id||item.employee_name}:${item.work_date}`;
      let day=days.get(key);if(!day){day={completed:false,first:null};days.set(key,day);}
      if(item.duration_minutes!=null){day.completed=true;total+=Number(item.duration_minutes)||0;}
      if(item.clock_in_at&&(!day.first||Date.parse(item.clock_in_at)<Date.parse(day.first.clock_in_at)))day.first=item;
    }
    const workDays=[...days.values()].filter(day=>day.completed).length;
    const lateDays=[...days.values()].filter(day=>(day.first?.attendance_labels||[]).includes('지각')).length;
    return {workDays,lateDays,averageMinutes:workDays?Math.round(total/workDays):0};
  }
  root.omgAttendanceSummary=summarize;
  if(typeof module!=='undefined'&&module.exports)module.exports=summarize;
})(typeof window==='undefined'?globalThis:window);
