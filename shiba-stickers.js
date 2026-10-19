/* A fixed, local atlas whitelist: message text never supplies an image URL. */
window.OMSStickers=(()=>{
 const packs=[
  {file:'shiba-guest.webp',width:2098,height:749,labels:['환영해요','체크인','체크아웃','청소 중','청소 완료','수건 보충','침구 교체','짐 보관','비번 안내','조용히','금연','수리 중','확인 완료','감사해요']},
  {file:'shiba-daily.webp',width:1962,height:802,labels:['방긋','ㅋㅋㅋ','사랑해','최고','오케이','고마워','미안해','엉엉','화났어','헉!','음…','잘 자','축하해','파이팅']}
 ];
 const entries=packs.flatMap((pack,p)=>pack.labels.map((label,index)=>({pack:p,index,label,token:`[시바:${label}]`}))),byToken=new Map(entries.map(entry=>[entry.token,entry]));
 const pattern=()=>/\[시바:[^\]\r\n]{1,20}\]/g;
 function art(entry,className='oms-sticker'){
  const p=packs[entry.pack],width=p.width/7,height=p.height/2,x=(entry.index%7)*width,y=Math.floor(entry.index/7)*height;
  return `<svg class="${className}" viewBox="${x} ${y} ${width} ${height}" role="img" aria-label="${entry.label}" focusable="false"><image href="assets/chat-stickers/${p.file}" width="${p.width}" height="${p.height}"/></svg>`;
 }
 function preview(text){return String(text??'').replace(pattern(),token=>byToken.has(token)?'🐕 '+byToken.get(token).label:token);}
 function html(text,escape){let end=0,parts=[];String(text??'').replace(pattern(),(token,offset)=>{const entry=byToken.get(token);if(!entry)return token;parts.push(escape(String(text).slice(end,offset)),art(entry));end=offset+token.length;return token;});parts.push(escape(String(text??'').slice(end)));return parts.join('');}
 return {entries,art,preview,html};
})();
