(function(root){
 'use strict';
 function replyStatus(room,now=Date.now()){
  const since=Date.parse(room?.unanswered_since||'');
  if(!Number.isFinite(since))return '';
  const elapsed=Math.max(0,now-since),minutes=Math.floor(elapsed/60000);
  return elapsed>10*60000?`미응답 지연 ${minutes}분`:'미응답';
 }
 root.omgGuestReplyStatus=replyStatus;
 if(typeof module!=='undefined'&&module.exports)module.exports=replyStatus;
})(typeof window==='undefined'?globalThis:window);
