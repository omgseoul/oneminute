(function(){
 const channels=[['airbnb','에어비앤비'],['booking','부킹닷컴'],['agoda','아고다'],['expedia','익스피디아'],['direct','다이렉트 예약']];
 function read(item){const c=item?.guest_context;return c&&['online','onsite'].includes(c.kind)?c:null;}
 function date(s){return /^\d{4}-\d{2}-\d{2}$/.test(s||'')?s.slice(5).replace('-','.'):'—';}
 function render(item){const c=read(item);if(!c)return null;const node=(tag,cls,value)=>{const n=document.createElement(tag);n.className=cls;if(value!==undefined)n.textContent=value;return n;};
  const box=node('div','guest-popup-card'),strip=node('div','guest-popup-strip'),room=String(c.room||'객실 미정');strip.append(node('strong','guest-popup-room',/^\d+$/.test(room)?room+'호':room),node('span','guest-popup-dates','체크인 '+date(c.arrival)+' → 체크아웃 '+date(c.departure)),node('strong','guest-popup-property',[...String(c.property||'')].slice(0,3).join('')));
  if(c.kind==='online'&&c.channel){const source=String(c.channel),match=channels.find(([key])=>source.toLowerCase().includes(key)),button=node('button','guest-popup-channel');button.type='button';button.title=match?.[1]||source;button.setAttribute('aria-label',button.title);if(match){const img=document.createElement('img');img.src='assets/booking-channels/'+match[0]+'.svg';img.alt=button.title;button.append(img);}else button.textContent=[...source][0];button.onclick=()=>{let tip=box.querySelector('.guest-popup-source');if(!tip){tip=node('span','guest-popup-source',button.title);strip.append(tip);}else tip.remove();};strip.append(button);}
  let body=String(item.message||'');if(c.kind==='online'){body=body.replace(/^\[OMS-ONLINE:[0-9]+\]\s*/,'');if(c.guest&&body.startsWith(c.guest+'\n'))body=body.slice(c.guest.length+1);}
  box.append(strip,node('strong','guest-popup-name',c.guest||'게스트'),node('div','guest-popup-message',body),node('small','guest-popup-time',c.sent||''));return box;
 }
 window.OMSGuestMessageCard={read,render,title:c=>c.kind==='online'?'온라인 게스트 메세지':'현장 게스트 메세지'};
})();
