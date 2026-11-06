window.EmployeeLoginFields=(()=>{
 const duplicate='동일한 아이디가 있습니다. 새로운 아이디를 입력해주세요.';
 const normalize=v=>v.trim().toLocaleLowerCase();
 let showing=false;
 function report(error){if(error.message!==duplicate||showing)return;showing=true;AccountChatPreferences.showDialog({title:'아이디 확인',message:duplicate}).finally(()=>showing=false);}
 function mount(row,employee,host){
  const name=row.querySelector('.account-name'),id=row.querySelector('.employee-login-id');let manual=!!employee;
  const conflicts=value=>[...host.querySelectorAll('.employee-login-id')].some(other=>other!==id&&normalize(other.value)===normalize(value));
  function check(){const value=id.value.trim();if(value&&conflicts(value)){id.value='';manual=true;report(Error(duplicate));return false;}return true;}
  name.addEventListener('change',()=>{if(!manual){id.value=name.value.trim();check();}});
  id.addEventListener('input',()=>manual=true);
  id.addEventListener('change',check);
  row.ensureLoginId=()=>{if(!manual&&!id.value)id.value=name.value.trim();if(!check())throw Error(duplicate);};
 }
 function validate(host){const ids=new Set();for(const row of host.querySelectorAll('.employee-account')){row.ensureLoginId?.();const value=normalize(row.querySelector('.employee-login-id').value);if(!value)throw Error('근무자 아이디를 입력해주세요.');if(ids.has(value)){report(Error(duplicate));throw Error(duplicate);}ids.add(value);}}
 return{mount,validate,report};
})();
