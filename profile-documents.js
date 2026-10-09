window.OMSProfileDocuments={
 async load(session){
  const host=document.getElementById('profileContracts');
  try{
   const data=await OMSContracts.call(session.accessToken,'list');host.replaceChildren();
   if(!data.contracts.length){const p=document.createElement('p');p.textContent='근로계약서 · 작성전';p.style.cssText='font-size:13px;color:#718198';host.append(p);}
   for(const c of data.contracts){
    const row=document.createElement('div');row.style.cssText='display:flex;align-items:center;gap:8px;padding:12px 0;border-top:1px solid #dfe8f4';
    const a=document.createElement('a');a.href='contracts.html?id='+encodeURIComponent(c.id);a.style.cssText='flex:1;color:#183153;text-decoration:none;font-size:13px;font-weight:750';a.textContent=c.title+' · '+OMSContracts.status[c.status]+' ›';row.append(a);
    if(c.status==='signed'){const pdf=document.createElement('button');pdf.type='button';pdf.textContent='PDF';pdf.style.cssText='border:0;border-radius:10px;padding:12px;background:#eaf2ff;color:#2467bd;font-weight:750';pdf.onclick=async()=>{pdf.disabled=true;try{const r=await OMSContracts.call(session.accessToken,'pdf',{id:c.id});location.href=r.url;}catch(e){alert(e.message);}finally{pdf.disabled=false;}};row.append(pdf);}
    host.append(row);
   }
   const id=new URLSearchParams(location.search).get('contract');if(id&&data.contracts.some(c=>c.id===id))location.replace('contracts.html?id='+encodeURIComponent(id));
  }catch(e){host.textContent=e.message;const retry=document.createElement('button');retry.type='button';retry.textContent='다시 불러오기';retry.onclick=()=>this.load(session);host.append(retry);}
 }
};
