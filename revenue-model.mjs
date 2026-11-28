export const DAY=86400000;
export const iso=t=>new Date(t).toISOString().slice(0,10);
export const stamp=s=>Date.parse(s+'T00:00:00Z');
export function validRange(from,to){return /^\d{4}-\d{2}-\d{2}$/.test(from)&&/^\d{4}-\d{2}-\d{2}$/.test(to)&&Number.isFinite(stamp(from))&&Number.isFinite(stamp(to))&&iso(stamp(from))===from&&iso(stamp(to))===to&&stamp(to)>=stamp(from)&&stamp(to)-stamp(from)<=730*DAY;}
export function unitFor(from,to){const days=(stamp(to)-stamp(from))/DAY+1;return days>93?'month':days>31?'week':'day';}
export function bucketKey(day,unit){const d=new Date(stamp(day));if(unit==='month')return day.slice(0,7)+'-01';if(unit==='week')d.setUTCDate(d.getUTCDate()-(d.getUTCDay()+6)%7);return iso(d);}
export function monthRange(month){if(!/^\d{4}-(0[1-9]|1[0-2])$/.test(month))throw Error('월을 확인해주세요.');const [y,m]=month.split('-').map(Number);return {from:month+'-01',to:iso(Date.UTC(y,m,0))};}
export function shiftMonth(month,n){const [y,m]=month.split('-').map(Number);return iso(Date.UTC(y,m-1+n,1)).slice(0,7);}
export function periodRange(mode,anchor,span=1){
 const day=anchor.slice(0,10),month=anchor.slice(0,7);
 if(mode==='year')return {from:anchor.slice(0,4)+'-01-01',to:anchor.slice(0,4)+'-12-31'};
 if(mode==='month')return {from:monthRange(shiftMonth(month,1-span)).from,to:monthRange(month).to};
 if(mode==='week'){const d=new Date(stamp(day));d.setUTCDate(d.getUTCDate()-(d.getUTCDay()+6)%7);return {from:iso(d),to:iso(+d+6*DAY)};}
 return {from:day,to:day};
}
export function validImport(from,to){return validRange(from,to)&&from.slice(0,7)===to.slice(0,7)&&(stamp(to)-stamp(from))/DAY<31;}
export function monthsIn(from,to){const result=[];for(let m=from.slice(0,7);m<=to.slice(0,7);m=shiftMonth(m,1))result.push(m);return result;}
export function channelName(v){const s=String(v||'').trim();if(/booking[.\s]?com/i.test(s))return 'Booking.com';if(/airbnb/i.test(s))return 'Airbnb';if(/agoda/i.test(s))return 'Agoda';if(/expedia/i.test(s))return 'Expedia';if(/^(direct|manual)$/i.test(s))return 'Direct';return s||'미등록';}
export function precision(currency){try{return new Intl.NumberFormat('en',{style:'currency',currency}).resolvedOptions().maximumFractionDigits;}catch{return 2;}}
export function summarize(rows,{from,to,basis='staying',unit='day',channels=null,currency='KRW'}){
 const buckets=new Map();for(let t=stamp(from);t<=stamp(to);t+=DAY){const key=bucketKey(iso(t),unit);if(!buckets.has(key))buckets.set(key,{key,amount:0,bookings:new Set(),nights:0,missing:0});}
 const byChannel=new Map(),byProperty=new Map(),bookings=new Set(),missing=new Set(),scale=10**precision(currency),seen=new Set();let total=0,nights=0;
 for(const r of rows){const identity=r.property_id+':'+r.id;if(seen.has(identity))continue;seen.add(identity);const channel=channelName(r.channel);if(r.currency!==currency||channels&&!channels.includes(channel))continue;
  const arrival=stamp(r.arrival),departure=stamp(r.departure),count=(departure-arrival)/DAY;
  const first=basis==='staying'?Math.max(arrival,stamp(from)):stamp(basis==='booked'?r.booked:r.arrival),last=basis==='staying'?Math.min(departure-DAY,stamp(to)):first;
  if(!Number.isFinite(first)||!Number.isFinite(last)||first>last||first<stamp(from)||last>stamp(to)||basis==='staying'&&count<=0)continue;
  const known=typeof r.price==='number'&&Number.isFinite(r.price)&&r.price>=0,minor=known?Math.round(r.price*scale):0;let amount=0,stayNights=0;const parts={};
  for(let t=first;t<=last;t+=DAY){const bucket=buckets.get(bucketKey(iso(t),unit));if(!bucket)continue;
   // Cumulative rounding preserves the exact booking total across month/year boundaries.
   const n=(t-arrival)/DAY,part=known?(basis==='staying'?Math.round(minor*(n+1)/count)-Math.round(minor*n/count):minor):0;
   bucket.amount+=part;parts[bucket.key]=(parts[bucket.key]||0)+part;bucket.bookings.add(identity);if(basis==='staying'){bucket.nights++;stayNights++;}if(!known)bucket.missing++;amount+=part;
  }
  bookings.add(identity);if(!known)missing.add(identity);total+=amount;nights+=stayNights;
  for(const [map,key] of [[byChannel,channel],[byProperty,r.property_id]]){const group=map.get(key)||{key,amount:0,bookings:0,periods:{}};group.amount+=amount;group.bookings++;for(const [period,value] of Object.entries(parts))group.periods[period]=(group.periods[period]||0)+value;map.set(key,group);}
 }
 return {total:total/scale,count:bookings.size,missing:missing.size,nights,buckets:[...buckets.values()].map(x=>({...x,amount:x.amount/scale,bookings:x.bookings.size})),channels:[...byChannel.values()].map(x=>({...x,amount:x.amount/scale,periods:Object.fromEntries(Object.entries(x.periods).map(([k,v])=>[k,v/scale]))})),properties:[...byProperty.values()].map(x=>({...x,amount:x.amount/scale,periods:Object.fromEntries(Object.entries(x.periods).map(([k,v])=>[k,v/scale]))}))};
}
export function coverage(properties,from,to){return properties.every(p=>p.connected&&Array.from({length:(stamp(to)-stamp(from))/DAY+1},(_,i)=>iso(stamp(from)+i*DAY)).every(day=>(p.coverage||[]).some(c=>c.from<=day&&c.to>=day)));}
export function currencyReports(rows,options){
 const currencies=[...new Set(rows.filter(r=>!options.channels||options.channels.includes(channelName(r.channel))).map(r=>r.currency))].sort((a,b)=>a==='UNKNOWN'?1:b==='UNKNOWN'?-1:a.localeCompare(b));
 return currencies.map(currency=>({currency,...summarize(currency==='UNKNOWN'?rows.map(r=>r.currency==='UNKNOWN'?{...r,price:null}:r):rows,{...options,currency})})).filter(r=>r.count);
}
