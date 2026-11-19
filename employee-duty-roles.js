window.EmployeeDutyRoles=(()=>{
 const states=new WeakMap();
 async function rpc(token,property,action,data={}){const {data:v,error}=await omgSupabase.rpc('employee_duty_roles',{p_access_token:token,p_property_id:property,p_action:action,p_data:data});if(error||!v?.ok)throw Error(error?.message||v?.message||'역할을 불러오지 못했습니다.');return v;}
 function mount(row,employee){
  const box=document.createElement('div');box.className='employee-duty-roles';box.setAttribute('role','group');box.setAttribute('aria-label','역할');box.innerHTML='<span>역할</span>'+[['reservation','예약관리'],['onsite','현장관리'],['cleaning','청소']].map(([key,label])=>`<label><input type="checkbox" value="${key}" ${employee?'disabled':''}>${label}</label>`).join('');
  row.querySelector('.employee-bank-account').closest('label').after(box);const state={dirty:false,loaded:!employee};states.set(row,state);box.onchange=()=>state.dirty=true;
 }
 async function load(host,token,property){const rows=[...host.children];try{const v=await rpc(token,property,'get'),records=new Map(v.employees.map(x=>[x.employee_id,x.roles]));for(const row of rows){if(!row.isConnected)continue;const s=states.get(row);if(!s)continue;for(const input of row.querySelectorAll('.employee-duty-roles input')){if(!s.dirty)input.checked=(records.get(row.dataset.employeeId)||[]).includes(input.value);input.disabled=false;}s.loaded=true;}}catch(e){throw Error('역할 정보를 불러오지 못했습니다. '+e.message);}}
 async function save(host,token,property){for(const row of host.children){const s=states.get(row);if(!s?.dirty)continue;if(!s.loaded||!row.dataset.employeeId)throw Error('계정 정보를 다시 불러온 뒤 역할을 저장해주세요.');await rpc(token,property,'save',{employee_id:row.dataset.employeeId,roles:[...row.querySelectorAll('.employee-duty-roles input:checked')].map(i=>i.value)});s.dirty=false;}}
 return{mount,load,save};
})();
