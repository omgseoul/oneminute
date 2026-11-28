// Beds24 apiSourceId=0 means Direct. Missing source metadata is not Direct.
// A known provider ID wins over display/referral labels (e.g. Booking + Direct referrer).
export function isDirectBooking(booking){
 const id=String(booking.apiSourceId??'').trim();
 if(/^\d+$/.test(id))return /^0+$/.test(id);
 const source=[booking.apiSource,booking.channel,booking.referer].find(v=>typeof v==='string'&&v.trim());
 return /^(direct(?:booking)?|manual(?:booking)?|직접(?:예약)?|다이렉트(?:예약)?)$/.test(String(source||'').toLowerCase().replace(/[\s_-]+/g,''));
}
