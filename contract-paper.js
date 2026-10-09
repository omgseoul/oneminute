window.OMSContractPaper=(()=>{
 const text=(el,value)=>{el.textContent=value??'';return el;};
 const make=(tag,className,value)=>{const el=document.createElement(tag);if(className)el.className=className;if(value!==undefined)text(el,value);return el;};
 const date=value=>value?new Date(value).toLocaleDateString('ko-KR',{timeZone:'Asia/Seoul'}):'';
 function sections(content,title){const lines=String(content||'').split(/\r?\n/),result=[],lead=[];let current=null;for(const raw of lines){const line=raw.trim();if(!line)continue;if(!result.length&&!lead.length&&(line===String(title||'').trim()||/^(표준|단시간|기타) 근로계약서$/.test(line)))continue;const hit=line.match(/^(\d+)\.\s*(.+)$/);if(hit){current={number:hit[1],title:hit[2],lines:[]};result.push(current);}else if(current)current.lines.push(line);else lead.push(line);}return{lead,sections:result};}
 function find(groups,number){return groups.find(group=>group.number===String(number));}
 function tableRow(table,label,lines){if(!lines?.length)return;const tr=document.createElement('tr'),value=document.createElement('td');for(const line of lines){const row=make('div','formal-paper-entry');const parts=line.match(/^([^:：]{1,28})[:：]\s*(.+)$/);if(parts){row.append(make('strong','',parts[1]+': '),document.createTextNode(parts[2]));}else row.textContent=line;value.append(row);}tr.append(text(document.createElement('th'),label),value);table.append(tr);}
 function render(host,c,{signatures=true}={}){
  host.replaceChildren();host.classList.add('formal-contract-paper');
  const kind={standard:'표준 근로계약서',parttime:'단시간 근로계약서',other:'기타 계약서'}[c.contract_fields?.kind]||'근로계약서',header=make('header','formal-paper-head'),heading=make('div');heading.append(make('h2','formal-paper-title',c.title||'근로계약서'),make('p','formal-paper-subtitle',kind));
  const meta=make('p','formal-paper-meta');meta.append(document.createTextNode(c.signed_at?'전자서명 완료':'계약서 미리보기'));header.append(heading,meta);host.append(header,make('div','formal-paper-rule'));
  const parsed=sections(c.content,c.title),intro=make('p','formal-paper-intro',parsed.lead.join(' '));if(intro.textContent)host.append(intro);
  const terms=document.createElement('table');terms.className='formal-paper-terms';terms.setAttribute('aria-label','주요 근로조건');const period=find(parsed.sections,1),work=find(parsed.sections,2),time=find(parsed.sections,3),pay=find(parsed.sections,5);
  tableRow(terms,'계약기간',period?.lines);
  if(work){tableRow(terms,'근무장소',[work.lines.find(line=>line.startsWith('근무장소:'))?.replace(/^근무장소:\s*/,'')].filter(Boolean));tableRow(terms,'업무 내용',[work.lines.find(line=>line.startsWith('업무 내용:'))?.replace(/^업무 내용:\s*/,'')].filter(Boolean));}
  tableRow(terms,'근무시간',time?.lines);tableRow(terms,'임금',pay?.lines);if(terms.rows.length)host.append(terms);
  let clauseNumber=0;for(const group of parsed.sections.filter(group=>!['1','2','3','5','7'].includes(group.number))){const section=make('section','formal-paper-clause');section.append(make('b','',`제${++clauseNumber}조`));const copy=make('div');copy.append(make('h3','',group.title));for(const line of group.lines.filter(line=>!/^작성일\s*[:：]/.test(line)))copy.append(make('p','',line));section.append(copy);host.append(section);}
  const parties=find(parsed.sections,7),partyInfo={};for(const line of parties?.lines||[]){const split=line.indexOf(':');if(split>0)partyInfo[line.slice(0,split).trim()]=line.slice(split+1).trim();}
  if(signatures&&(c.employer_signature||c.employee_signature)){host.append(make('p','formal-paper-closing','양 당사자는 계약 내용을 충분히 확인하였으며 전자서명으로 계약을 체결합니다.'));
   host.append(make('p','formal-paper-date',c.contract_fields?.written_date||date(c.signed_at)));
   const signed=make('div','formal-paper-signatures');for(const [role,rows,src] of [['사업주',[['사업장',partyInfo['사업장명']||c.property_name],['성명',partyInfo['사업주명']||c.employer_name],['연락처',partyInfo['사업장 연락처']],['주소',partyInfo['사업장 주소']]],c.employer_signature],['근로자',[['성명',partyInfo['근로자명']||c.employee_name],['연락처',partyInfo['근로자 연락처']],['주소',partyInfo['근로자 주소']]],c.employee_signature]]){const box=make('section','formal-paper-sign');box.append(make('strong','',role));for(const [label,value] of rows.filter(row=>row[1])){const row=make('div','formal-paper-sign-row');row.append(make('span','',label),make('b','',value));box.append(row);}if(src){const signature=make('div','formal-paper-signature');signature.append(make('span','','전자서명'));const img=document.createElement('img');img.alt=role+' 서명';img.src=src;signature.append(img);box.append(signature);}signed.append(box);}host.append(signed);
  }
  const footer=make('footer','formal-paper-footer');footer.append(make('span','',c.id?'계약서 번호 '+String(c.id).slice(0,8).toUpperCase():''),make('span','',signatures&&c.signed_at?'전자서명 완료':''));host.append(footer);return host;
 }
 return{render,sections};
})();
