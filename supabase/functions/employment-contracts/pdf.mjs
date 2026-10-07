export function createContractPdfRenderer({PDFDocument,fontkit,rgb,fetcher=fetch}){
 let fontPromise;
 const fontBytes=()=>fontPromise||(fontPromise=fetcher('https://cdn.jsdelivr.net/gh/google/fonts@16680f8688ffcd467d2eb2146a9ce0343404581d/ofl/nanumgothic/NanumGothic-Regular.ttf',{signal:AbortSignal.timeout(15000)}).then(async r=>{if(!r.ok)throw Error('계약서 글꼴을 불러오지 못했습니다. 다시 시도해주세요.');return new Uint8Array(await r.arrayBuffer());}).catch(e=>{fontPromise=null;throw e;}));
 async function setup(){const pdf=await PDFDocument.create();pdf.registerFontkit(fontkit);const font=await pdf.embedFont(await fontBytes(),{subset:false});return{pdf,font};}
 async function validate(contract,signature){const{pdf,font}=await setup(),supported=new Set(font.getCharacterSet());const text=[contract.title,contract.content,contract.employer_name,contract.employee_name,contract.property_name].join('\n');const missing=[...new Set([...text].filter(c=>!['\n','\r','\t'].includes(c)&&!supported.has(c.codePointAt(0))))];if(missing.length)throw Error('PDF에서 지원하지 않는 문자를 바꿔주세요: '+missing.slice(0,12).join(' '));if(!/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(signature||'')||signature.length>200000)throw Error('서명을 다시 입력해주세요.');const image=await pdf.embedPng(signature);if(image.width<100||image.height<40||image.width>1600||image.height>800)throw Error('서명 크기가 올바르지 않습니다.');}
 async function render(c){const{pdf,font}=await setup();pdf.setTitle(c.title);pdf.setAuthor('OMS');pdf.setSubject('근로계약서 '+c.id);pdf.setCreationDate(new Date(c.signed_at));pdf.setModificationDate(new Date(c.signed_at));let page,y;const navy=rgb(.094,.192,.325),gray=rgb(.40,.46,.55),margin=48,width=499;
 function addPage(){page=pdf.addPage([595,842]);y=785;page.drawText('OMS | 근로계약서',{x:margin,y,font,size:10,color:gray});y-=34;}
 function line(text,size=11,color=navy){if(y<70)addPage();page.drawText(text,{x:margin,y,font,size,color});y-=size*1.65;}
 const widths=new Map();function charWidth(ch,size){const key=ch+'|'+size;if(!widths.has(key))widths.set(key,font.widthOfTextAtSize(ch,size));return widths.get(key);}
 function paragraph(text,size=11){for(const para of String(text||'').replaceAll('\t','    ').split(/\r?\n/)){let part='',used=0;for(const ch of para){const next=charWidth(ch,size);if(used+next>width){line(part,size);part=ch;used=next;}else{part+=ch;used+=next;}}line(part,size);}}
 addPage();paragraph(c.title,19);y-=8;paragraph(c.content);y-=15;
 if(y<420)addPage();line('서명 및 확인',14);paragraph('사업주: '+c.employer_name,11);line('확인 시각: '+new Date(c.sent_at).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'}),9,gray);
 const employer=await pdf.embedPng(c.employer_signature);page.drawImage(employer,{x:margin,y:y-55,width:165,height:55});y-=75;
 paragraph('근로자: '+c.employee_name,11);line('서명 시각: '+new Date(c.signed_at).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'}),9,gray);
 const employee=await pdf.embedPng(c.employee_signature);page.drawImage(employee,{x:margin,y:y-55,width:165,height:55});y-=78;
 paragraph('양 당사자는 계약 내용을 확인하고 전자서명 및 PDF 보관에 동의했습니다.',9);paragraph('계약서 번호: '+c.id,8);paragraph('원문 확인값: '+c.content_hash,8);
 pdf.getPages().forEach((p,i)=>p.drawText(`${i+1} / ${pdf.getPageCount()}`,{x:270,y:32,font,size:9,color:gray}));return pdf.save();}
 return{validate,render};
}
