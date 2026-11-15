(function(root){
 'use strict';
 const key=value=>String(value||'').normalize('NFKC').trim().toLowerCase();
 function merge(existing,inventory){
  const groups=existing.map(g=>({name:g.name,rooms:[...(g.rooms||[])]})),seen=new Set(groups.flatMap(g=>g.rooms.length?g.rooms:[g.name]).map(key));let added=0,skipped=0;
  for(const type of inventory||[]){
   const names=[...new Map((type.units||[]).map(u=>String(u.name||'').trim()).filter(Boolean).map(n=>[key(n),n])).values()];
   if(!names.length){skipped++;continue;}
   const missing=names.filter(n=>!seen.has(key(n)));if(!missing.length)continue;
   let group=groups.find(g=>g.rooms.length&&key(g.name)===key(type.name))||groups.find(g=>g.rooms.some(n=>names.some(v=>key(v)===key(n))));
   if(!group){const name=String(type.name||'객실 Unit').trim();if(name.length>40)throw Error('Beds24 객실타입 이름이 40자를 넘습니다. 이름을 줄인 후 다시 불러와주세요.');group={name,rooms:[]};groups.push(group);}
   group.rooms.push(...missing);missing.forEach(n=>seen.add(key(n)));added+=missing.length;
  }
  if(groups.length>30||groups.some(g=>g.rooms.join(', ').length>800))throw Error('객실정보가 입력 한도를 넘습니다. 객실타입은 30개, 타입별 객실번호는 800자까지 등록할 수 있습니다.');
  return {groups,added,skipped};
 }
 root.OMSRoomImport={merge};
})(typeof window==='undefined'?globalThis:window);
