/* Pure date-only recurrence, shared by list/calendar tests. Server is authoritative. */
(function(root){
 const date=s=>new Date(s+'T12:00:00Z'),key=d=>d.toISOString().slice(0,10),days=(a,b)=>Math.round((date(b)-date(a))/86400000);
 function occurrence(t,day){if(day<t.start_date)return false;const n=Number(t.repeat_every);if(!Number.isInteger(n)||n<1)return false;if(t.repeat_unit==='day'||t.repeat_unit==='week')return days(t.start_date,day)%(n*(t.repeat_unit==='week'?7:1))===0;
  if(t.repeat_unit!=='month')return false;const start=date(t.start_date),d=date(day),months=(d.getUTCFullYear()-start.getUTCFullYear())*12+d.getUTCMonth()-start.getUTCMonth();const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();return months%n===0&&d.getUTCDate()===Math.min(start.getUTCDate(),last);
 }
 function label(t){return `매 ${t.repeat_every}${({day:'일',week:'주',month:'개월'})[t.repeat_unit]}`;}
 function clip(s,n=5){const a=Array.from(String(s||''));return a.length>n?a.slice(0,n).join('')+'..':a.join('');}
 function today(timezone='Asia/Seoul'){return new Intl.DateTimeFormat('en-CA',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
 const api={occurrence,label,clip,today,key,date};if(typeof module!=='undefined')module.exports=api;else root.OMSTaskDates=api;
})(globalThis);
