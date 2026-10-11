(function(root){
  function parts(value,timezone='Asia/Seoul'){
    if(!value)return null;
    const date=new Date(value);if(Number.isNaN(date.getTime()))return null;
    const p=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(date).map(x=>[x.type,x.value]));
    return {date:`${p.year}-${p.month}-${p.day}`,time:`${p.hour}:${p.minute}`};
  }
  function range(start,end,timezone='Asia/Seoul',workDate){
    const a=parts(start,timezone),b=parts(end,timezone),dated=!!(a&&b&&a.date!==b.date||a&&workDate&&a.date!==workDate||b&&workDate&&b.date!==workDate);
    const year=!!(a&&b&&a.date.slice(0,4)!==b.date.slice(0,4));
    const label=p=>p?`${dated?`${(year?p.date:p.date.slice(5)).replaceAll('-','/')} `:''}${p.time}`:'-';
    return `${label(a)} ~ ${label(b)}`;
  }
  function nextDate(date){const d=new Date(`${date}T00:00:00Z`);d.setUTCDate(d.getUTCDate()+1);return d.toISOString().slice(0,10);}
  function future(workDate,start,end,timezone='Asia/Seoul',now=new Date()){
    const p=parts(now,timezone),current=`${p.date}T${p.time}`;
    return `${workDate}T${start}`>current||`${end<=start?nextDate(workDate):workDate}T${end}`>current;
  }
  const api={parts,range,nextDate,future};root.OMSAttendanceTime=api;if(typeof module==='object')module.exports=api;
})(typeof window==='object'?window:globalThis);
