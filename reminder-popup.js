(function(root){
 function parse(message,sender='',now=new Date()){
  const lines=String(message||'').replace(/\\n/g,'\n').split('\n');
  const category=/^(To do 알림|일정 알림)$/.test(lines[0].trim())?lines.shift().trim():/^(To do 알림|일정 알림)$/.test(sender)?sender:null;
  if(!category)return null;
  const calendar=category==='일정 알림',prefix=lines[0]?.match(/^(?:(\d+)일 (지연|후)|오늘|내일|지연|등록):\s*/);
  let days=prefix?.[1]?Number(prefix[1])*(prefix[2]==='지연'?-1:1):prefix?.[0].startsWith('오늘')?0:prefix?.[0].startsWith('내일')?1:null;
  let overdue=!calendar&&!!prefix?.[0].includes('지연');
  const dateLine=lines.find(x=>/^(마감|일정): \d{4}-\d{2}-\d{2} /.test(x))||'',zone=lines.find(x=>x.startsWith('시간대: '))?.slice(5)||'Asia/Seoul';
  if(dateLine){try{const parts=new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now);const v=t=>parts.find(p=>p.type===t).value;days=Math.round((Date.parse(dateLine.slice(4,14)+'T00:00:00Z')-Date.parse(`${v('year')}-${v('month')}-${v('day')}T00:00:00Z`))/86400000);overdue=!calendar&&days<0;}catch(_){}}
  const title=(lines[0]||'').replace(prefix?.[0]||/^$/,'')||'내용을 확인해주세요.';
  const timing=days===null?'':days===0?'(오늘)':days<0?(overdue?`(${-days}일 지연)`:'(지난 일정)'):`(${days}일 후)`;
  return {calendar,overdue,days,title,dateLine,heading:overdue?'지연된 업무':category,timing,
   guidance:overdue?'기한이 지났습니다. 지금 확인해주세요.':calendar?'예정된 일정을 확인해주세요.':'할 일을 확인하고 완료해주세요.',
   href:calendar?'calendar.html':'mission.html',button:calendar?'일정 보기':'할 일 보기'};
 }
 root.OMSReminderPopup={parse};if(typeof module!=='undefined')module.exports={parse};
})(typeof window==='undefined'?globalThis:window);
