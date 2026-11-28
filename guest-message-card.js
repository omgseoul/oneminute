(function(){
 const channels=[['airbnb','에어비앤비'],['booking','부킹닷컴'],['agoda','아고다'],['expedia','익스피디아'],['direct','다이렉트 예약']];
 function channelIcon(value,node){
  const source=String(value||'').trim(),match=channels.find(([key])=>key==='booking'?/booking[. _-]*com|^booking$/i.test(source):source.toLowerCase().includes(key));
  const icon=node('span','guest-popup-channel-icon');
  icon.setAttribute('aria-hidden','true');
  if(match){const image=node('img','');image.src='assets/booking-channels/'+match[0]+'.svg';image.alt='';icon.append(image);}
  else{icon.classList.add('guest-popup-channel-initial');icon.textContent=[...source][0]?.toUpperCase()||'?';}
  return icon;
 }
 function read(item){const c=item?.guest_context;return c&&['online','onsite','same_day'].includes(c.kind)?c:null;}
 function date(s){return /^\d{4}-\d{2}-\d{2}$/.test(s||'')?s.slice(5).replace('-','.'):'—';}
 function render(item){const c=read(item);if(!c)return null;const node=(tag,cls,value)=>{const n=document.createElement(tag);n.className=cls;if(value!==undefined)n.textContent=value;return n;};
  if(c.kind==='same_day'){
   const box=node('div','guest-popup-card booking-popup-card'),strip=node('div','guest-popup-strip'),room=String(c.room||'객실 미정'),source=String(c.channel||'출처 미확인'),channel=/booking[. _-]*com|^booking$/i.test(source)?'Booking.com':source;
   const summary=node('strong','booking-popup-summary',[/^\d+$/.test(room)?room+'호':room,c.property||'',channel].filter(Boolean).join(' · '));
   if(c.channel)summary.prepend(channelIcon(c.channel,node));
   strip.append(summary,node('span','guest-popup-dates',date(c.arrival)+' → '+date(c.departure)),node('strong','guest-popup-name',c.guest||'게스트'));box.append(strip);if(c.sent)box.append(node('small','guest-popup-time',c.sent));return box;
  }
  const box=node('div','guest-popup-card'),strip=node('div','guest-popup-strip'),room=String(c.room||'객실 미정');strip.append(node('strong','guest-popup-room',/^\d+$/.test(room)?room+'호':room),node('span','guest-popup-dates',date(c.arrival)+' → '+date(c.departure)),node('strong','guest-popup-property',[...String(c.property||'')].slice(0,3).join('')));
  if(c.kind==='online'&&c.channel){const source=String(c.channel),match=channels.find(([key])=>key==='booking'?/booking[. _-]*com|^booking$/i.test(source):source.toLowerCase().includes(key)),button=node('button','guest-popup-channel');button.type='button';button.title=match?.[1]||source;button.setAttribute('aria-label',button.title);button.append(channelIcon(source,node));button.onclick=()=>{let tip=box.querySelector('.guest-popup-source');if(!tip){tip=node('span','guest-popup-source',button.title);strip.append(tip);}else tip.remove();};strip.append(button);}
  let body=String(item.message||'');if(c.kind==='online'){body=body.replace(/^\[OMS-ONLINE:[0-9]+\]\s*/,'');if(c.guest&&body.startsWith(c.guest+'\n'))body=body.slice(c.guest.length+1);}
  strip.append(node('strong','guest-popup-name',c.guest||'게스트'));box.append(strip,node('div','guest-popup-message',c.translation||body));if(c.translation&&c.original)box.append(node('div','guest-popup-original','원문: '+c.original));if(c.ai_status==='completed'||c.ai_status==='unavailable'){const ai=node('div','guest-popup-ai '+(c.ai_status==='completed'?'is-complete':'is-unavailable'));ai.append(node('strong','guest-popup-ai-state',c.ai_status==='completed'?'자동답변 완료':'자동답변 불가'));if(c.ai_status==='completed'&&c.ai_reply)ai.append(node('div','guest-popup-ai-answer',c.ai_reply));box.append(ai);}box.append(node('small','guest-popup-time',c.sent||''));return box;
 }
 window.OMSGuestMessageCard={read,render,channelIcon:source=>channelIcon(source,(tag,cls)=>{const el=document.createElement(tag);el.className=cls;return el;}),title:c=>c.kind==='same_day'?'당일 예약 발생':c.kind==='online'?'온라인 게스트 메세지':'현장 게스트 메세지',fit:root=>{const el=root.querySelector('.booking-popup-summary');if(!el||!el.clientWidth)return;let size=12;el.style.fontSize=size+'px';while(size>7&&el.scrollWidth>el.clientWidth){size-=.5;el.style.fontSize=size+'px';}if(el.scrollWidth>el.clientWidth){el.style.transformOrigin='left center';el.style.transform='scaleX('+el.clientWidth/el.scrollWidth+')';}}};
})();
