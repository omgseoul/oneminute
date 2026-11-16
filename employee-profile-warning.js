window.EmployeeProfileWarning={async show(fields){
 if(!Array.isArray(fields)||!fields.length)return false;
 const dialog=document.createElement('dialog');dialog.className='employee-profile-reminder';
 dialog.innerHTML='<h2>근무자 정보를 입력해주세요</h2><p>미입력된 항목이 있습니다.</p><strong></strong><small>출근보고는 정상적으로 완료되었습니다.</small><div><button type="button" data-later>나중에</button><button type="button" data-edit>내 정보 입력</button></div>';
 dialog.querySelector('strong').textContent=fields.join(' · ');document.body.append(dialog);
 return new Promise(resolve=>{const finish=edit=>{dialog.close();dialog.remove();resolve(edit);};dialog.querySelector('[data-later]').onclick=()=>finish(false);dialog.querySelector('[data-edit]').onclick=()=>finish(true);dialog.addEventListener('cancel',event=>{event.preventDefault();finish(false);});dialog.showModal();});
}};
