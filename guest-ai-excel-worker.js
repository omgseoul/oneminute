// Pinned, local SheetJS CE. Parsing stays off the UI thread and never sends DATA externally.
importScripts('vendor/xlsx-0.20.3.mini.min.js','guest-ai-manual.js?v=20261127-rooms');
self.onmessage=event=>{try{
 const bytes=new Uint8Array(event.data),view=new DataView(bytes.buffer);if(bytes.length<22||bytes.length>5*1024*1024||view.getUint32(0,true)!==0x04034b50)throw Error('.xlsx 엑셀 파일을 선택해주세요.');
 // Inspect declared ZIP expansion before parsing; worker deadline is a second bound.
 let end=-1;for(let i=bytes.length-22;i>=Math.max(0,bytes.length-65557);i--)if(view.getUint32(i,true)===0x06054b50){end=i;break;}
 if(end<0)throw Error('엑셀 파일이 손상되었습니다. 다시 저장해주세요.');
 const count=view.getUint16(end+10,true);let pos=view.getUint32(end+16,true),expanded=0;if(count>2048)throw Error('파일 구성이 너무 큽니다. DATA 시트만 새 파일에 저장해주세요.');
 for(let i=0;i<count;i++){if(pos+46>end||view.getUint32(pos,true)!==0x02014b50)throw Error('지원하지 않는 엑셀 형식입니다.');if(view.getUint16(pos+8,true)&1)throw Error('암호를 해제한 엑셀 파일을 올려주세요.');expanded+=view.getUint32(pos+24,true);if(expanded>12*1024*1024)throw Error('엑셀 내용이 너무 큽니다. DATA 시트만 새 파일에 저장해주세요.');pos+=46+view.getUint16(pos+28,true)+view.getUint16(pos+30,true)+view.getUint16(pos+32,true);}
 const wb=XLSX.read(bytes,{type:'array',cellFormula:true,cellHTML:false,cellText:true,bookVBA:false});
 const candidates=wb.SheetNames.filter(name=>{const sh=wb.Sheets[name];return (sh.A1?.v==='번호'&&sh.C1?.v==='제목')||(sh.A1?.v==='제목'&&sh.B1?.v==='답변 내용');});
 const name=candidates.includes('AI 자동답변 DATA')?'AI 자동답변 DATA':candidates.length===1?candidates[0]:null;
 if(!name)throw Error(candidates.length>1?'매뉴얼 시트가 여러 개입니다. 올릴 지점의 시트만 별도 파일로 저장해주세요.':'첫 행의 번호·분류·제목·객실번호·답변 내용 헤더를 확인해주세요.');
 const sheet=wb.Sheets[name],values=new Map();
 for(const [ref,cell] of Object.entries(sheet)){if(ref.startsWith('!'))continue;const at=XLSX.utils.decode_cell(ref);if(cell.f)throw Error(`${at.r+1}행에 수식이 있습니다. 수식 대신 값으로 붙여넣어주세요.`);if(cell.t==='e')throw Error(`${at.r+1}행의 엑셀 오류 값을 확인해주세요.`);
  const value=String(cell.t==='n'?cell.v:cell.w??cell.v??'').replace(/\r\n?/g,'\n');if(!value.trim())continue;if(at.c>4)throw Error('번호·분류·제목·객실번호·답변 내용 다섯 열만 사용해주세요.');if(at.r>10000)throw Error('DATA를 시트 상단으로 옮겨주세요.');const row=values.get(at.r)||['','','','',''];row[at.c]=value;values.set(at.r,row);
 }
 const rows=GuestAIManual.parse([...values].sort((a,b)=>a[0]-b[0]).map(([,v])=>v));
 self.postMessage({ok:true,rows,sheet:name});
}catch(error){self.postMessage({ok:false,message:error.message||'엑셀 파일을 읽지 못했습니다.'});}};
