/* Date-only recurrence shared by calendar, editor preview and tests. Server is authoritative. */
(function(root){
 const date=s=>new Date(s+'T12:00:00Z'),key=d=>d.toISOString().slice(0,10),days=(a,b)=>Math.round((date(b)-date(a))/86400000),names=['일','월','화','수','목','금','토'];
 function occurrence(t,day){if(day<t.start_date)return false;const n=Number(t.repeat_every);if(!Number.isInteger(n)||n<1)return false;if(t.repeat_unit==='day')return days(t.start_date,day)%n===0;
  const start=date(t.start_date),d=date(day);if(t.repeat_unit==='week'){if(!t.repeat_weekdays?.length)return days(t.start_date,day)%(n*7)===0;const weeks=Math.floor((days(t.start_date,day)+start.getUTCDay())/7);return weeks%n===0&&t.repeat_weekdays.includes(d.getUTCDay());}
  if(t.repeat_unit!=='month')return false;const months=(d.getUTCFullYear()-start.getUTCFullYear())*12+d.getUTCMonth()-start.getUTCMonth(),last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate(),wanted=t.repeat_month_day??start.getUTCDate();return months%n===0&&d.getUTCDate()===(wanted===0?last:Math.min(wanted,last));
 }
 function label(t){const n=Number(t.repeat_every)||1;if(t.repeat_unit==='day')return `${n}일마다`;if(t.repeat_unit==='week')return `${n===1?'매주':n+'주마다'} ${(t.repeat_weekdays?.length?t.repeat_weekdays:[date(t.start_date).getUTCDay()]).map(d=>names[d]).join('·')}`;const md=t.repeat_month_day??date(t.start_date).getUTCDate();return `${n===1?'매월':n+'개월마다'} ${md===0?'말일':md+'일'}`;}
 function upcoming(t,from,count=3){const result=[],start=date(t.start_date>from?t.start_date:from);for(let i=0;i<37000&&result.length<count;i++){const d=new Date(+start+i*86400000),k=key(d);if(occurrence(t,k))result.push(k);}return result;}
 function clip(s,n=5){const a=Array.from(String(s||''));return a.length>n?a.slice(0,n).join('')+'..':a.join('');}
 function today(timezone='Asia/Seoul'){return new Intl.DateTimeFormat('en-CA',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
 const api={occurrence,label,upcoming,clip,today,key,date};if(typeof module!=='undefined')module.exports=api;else root.OMSTaskDates=api;
})(globalThis);
