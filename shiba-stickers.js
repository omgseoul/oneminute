/* A fixed, local atlas whitelist: message text never supplies an image URL. */
window.OMSStickers=(()=>{
 const packs=[
  {file:'shiba-guest.webp',width:1915,height:821,frames:[[30,110,277,384],[280,110,548,384],[565,110,810,384],[827,110,1068,388],[1076,134,1374,390],[1397,108,1634,384],[1640,105,1890,385],[30,450,273,723],[280,450,566,725],[574,450,817,725],[829,451,1065,725],[1084,447,1362,725],[1380,448,1646,725],[1650,465,1890,724]],labels:['환영해요','체크인','체크아웃','청소 중','청소 완료','수건 보충','침구 교체','짐 보관','비번 안내','조용히','금연','수리 중','확인 완료','감사해요']},
  {file:'shiba-daily.webp',width:1916,height:821,frames:[[20,120,267,380],[290,120,555,380],[570,120,820,380],[850,124,1100,380],[1120,124,1372,380],[1384,118,1618,380],[1640,132,1890,380],[15,475,277,728],[305,470,535,725],[560,480,814,725],[840,470,1082,728],[1083,480,1350,728],[1360,452,1628,732],[1650,470,1899,725]],labels:['방긋','ㅋㅋㅋ','사랑해','최고','오케이','고마워','미안해','엉엉','화났어','헉!','음…','잘 자','축하해','파이팅']}
 ];
 const entries=packs.flatMap((pack,p)=>pack.labels.map((label,index)=>({pack:p,index,label,token:`[시바:${label}]`}))),byToken=new Map(entries.map(entry=>[entry.token,entry]));
 const pattern=()=>/\[시바:[^\]\r\n]{1,20}\]/g;
 let clipSequence=0;
 function art(entry,className='oms-sticker'){
  const p=packs[entry.pack],[x,y,right,bottom]=p.frames[entry.index],width=right-x,height=bottom-y;
  const clip='oms-shiba-clip-'+(++clipSequence);
  return `<svg class="${className}" viewBox="${x} ${y} ${width} ${height}" role="img" aria-label="${entry.label}" focusable="false"><defs><clipPath id="${clip}" clipPathUnits="userSpaceOnUse"><rect x="${x}" y="${y}" width="${width}" height="${height}"/></clipPath></defs><image clip-path="url(#${clip})" href="assets/chat-stickers/${p.file}" width="${p.width}" height="${p.height}"/></svg>`;
 }
 function preview(text){return String(text??'').replace(pattern(),token=>byToken.has(token)?'🐕 '+byToken.get(token).label:token);}
 function html(text,escape){let end=0,parts=[];String(text??'').replace(pattern(),(token,offset)=>{const entry=byToken.get(token);if(!entry)return token;parts.push(escape(String(text).slice(end,offset)),art(entry));end=offset+token.length;return token;});parts.push(escape(String(text??'').slice(end)));return parts.join('');}
 return {entries,art,preview,html};
})();
