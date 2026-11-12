// Per-property policy is loaded privately with the job, never bundled into the public client.
export const HANDOFF_KO='문의하신 내용은 직원이 확인해서 다시 말씀드리겠습니다.';
export function fallbackReply(text=''){
 if(/[가-힣]/.test(text))return HANDOFF_KO;
 if(/[ぁ-ゖァ-ヺ]/.test(text))return 'お問い合わせ内容をスタッフが確認し、改めてご案内いたします。';
 if(/[\u4e00-\u9fff]/.test(text))return '工作人员会确认您的问题后再回复您。';
 return 'A staff member will check your inquiry and get back to you.';
}
export function propertyRules(job){return typeof job.support_policy==='string'?job.support_policy:'';}
export function enforcePropertyRouting(value,job){
 if(job.alert_rules||!job.support_policy)return {...value};
 const titles=new Map(job.data.map(r=>[String(r.id),r.title]));
 const sources=new Set(value.parts.flatMap(p=>p.sources).map(id=>titles.get(id)));
 // Hard floor for acknowledged incident categories, even if a model labels them "answer".
 if(sources.has('시설 고장·비상 신고'))return {...value,disposition:'urgent',reason:'시설 고장 비상 확인 필요'};
 if(sources.has('청소·청결 불만')&&value.disposition==='answer')return {...value,reply:fallbackReply(job.history.at(-1)?.content),disposition:'handoff',reason:'청소 불만 · 직원 및 사장 확인 필요'};
 if(sources.has('확인되지 않은 문의·직원 지원')&&value.disposition==='answer')return {...value,reply:fallbackReply(job.history.at(-1)?.content),disposition:'handoff',reason:'미확인 문의 · 직원 지원 필요'};
 return value;
}
