// Supabase owns authorization, message storage, routing and delivery records.
// Google FCM is only the native notification transport. No Firebase database/Auth.
const origins = new Set(['https://omgworks24.com', 'https://www.omgworks24.com', 'https://omgseoul.github.io']);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const topicPattern = /^property_[0-9]+_(?:staff|employee_[0-9a-f-]{36}|owner_[0-9a-f-]{36})$/i;
const encoder = new TextEncoder();
const normalMessagePrefix = '[[OMG_NORMAL_MESSAGE]]';
function base64url(bytes) { return btoa(String.fromCharCode(...bytes)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_'); }
function preview(text) {
  const value = String(text || '메세지');
  return [...(value.startsWith(normalMessagePrefix) ? value.slice(normalMessagePrefix.length) : value)].slice(0, 650).join('');
}

export function createBriefingDispatch({ env, fetcher = fetch, cryptoApi = crypto, now = () => Date.now() }) {
  let cachedToken, tokenUntil = 0;
  function credentials() {
    const account = JSON.parse(env('FCM_SERVICE_ACCOUNT') || '{}');
    if (!account.private_key || !account.client_email || !account.project_id) throw new Error('not_configured');
    if (account.project_id !== 'guesthouse-manager-ajh') throw new Error('wrong_fcm_project');
    return account;
  }
  async function oauth() {
    if (cachedToken && tokenUntil > now() + 60000) return cachedToken;
    const account = credentials(), issued = Math.floor(now() / 1000);
    const header = base64url(encoder.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
    const claims = base64url(encoder.encode(JSON.stringify({ iss: account.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: 'https://oauth2.googleapis.com/token',
      iat: issued, exp: issued + 3600 })));
    const pem = account.private_key.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
    const key = await cryptoApi.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
    const assertion = header + '.' + claims + '.' + base64url(new Uint8Array(await cryptoApi.subtle.sign('RSASSA-PKCS1-v1_5', key, encoder.encode(header + '.' + claims))));
    const response = await fetcher('https://oauth2.googleapis.com/token', { method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }), signal: AbortSignal.timeout(10000) });
    const data = await response.json();
    if (!response.ok || !data.access_token) throw new Error('fcm_auth_failed');
    cachedToken = data.access_token; tokenUntil = now() + Math.min(Number(data.expires_in) || 3600, 3600) * 1000;
    return cachedToken;
  }
  async function rpc(name, args) {
    const key = env('SUPABASE_SERVICE_ROLE_KEY');
    if (!key || !env('SUPABASE_URL')) throw new Error('not_configured');
    const response = await fetcher(env('SUPABASE_URL') + '/rest/v1/rpc/' + name, {
      method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify(args), signal: AbortSignal.timeout(10000)
    });
    const value = await response.json();
    if (!response.ok) throw new Error('database_failed');
    return value;
  }
  async function send(topic, data, deliveryId, validateOnly = false, device = null) {
    if (!topicPattern.test(topic)) throw new Error('invalid_topic');
    // Obtain transport authorization before taking a delivery lease.
    const bearer = await oauth();
    const deliveryKey = deliveryId + ':' + (device ? 'device:' + device.device_id : topic);
    const lease = validateOnly ? { claimed: true } : await rpc('claim_push_delivery', { p_key: deliveryKey });
    if (!lease.claimed) {
      if (lease.status === 'sent') return 'duplicate';
      throw new Error('delivery_in_progress');
    }
    let accepted = false;
    try {
      const response = await fetcher('https://fcm.googleapis.com/v1/projects/guesthouse-manager-ajh/messages:send', {
        method: 'POST', headers: { Authorization: 'Bearer ' + bearer, 'Content-Type': 'application/json' },
        body: JSON.stringify({ validate_only: validateOnly, message: { ...(device ? {token:device.token} : {topic}), data: !topic.endsWith('_staff') ? {...data,recipientKey:topic.replace(/^property_[0-9]+_/, '').replace('employee_','employee:').replace('owner_','owner:')} : data,
          android: { priority: 'high', ttl: data.mode === 'stop' ? '60s' : data.mode === 'urgent' ? '300s' : '3600s' } } }),
        signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) {
        const errorBody = await response.json().catch(()=>({}));
        if (device && errorBody.error?.details?.some(d=>d.errorCode === 'UNREGISTERED')) await rpc('invalidate_native_push',{p_device_id:device.device_id,p_fcm_token:device.token});
        if (response.status === 401) { cachedToken = null; tokenUntil = 0; }
        if (!validateOnly) await rpc('finish_push_delivery', { p_key: deliveryKey, p_lease_id: lease.lease_id, p_success: false });
        throw new Error('fcm_rejected');
      }
      accepted = true;
      if (!validateOnly) {
        const saved = await rpc('finish_push_delivery', { p_key: deliveryKey, p_lease_id: lease.lease_id, p_success: true });
        if (!saved.ok) throw new Error('delivery_record_failed');
      }
      return validateOnly ? 'validated' : 'sent';
    } catch (error) {
      // A timeout can occur after FCM accepted a message. Leave its lease intact.
      // Never immediately send via Firebase Cloud Functions as a fallback.
      throw new Error(accepted ? 'delivery_record_failed' : error.message);
    }
  }
  // Dedicated endpoint: accepts only stored bot_briefing messages. Existing
  // staff/guest/Telegram dispatchers are not modified or redeployed.
  return async req=>{
    const reply=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
    if(req.method!=='POST')return reply({ok:false},405);
    if(!env('PUSH_ADMIN_SECRET')||req.headers.get('x-webhook-secret')!==env('PUSH_ADMIN_SECRET'))return reply({ok:false},401);
    try{
      const raw=await req.text();if(raw.length>1000)return reply({ok:false},413);const body=JSON.parse(raw);
      if(!uuid.test(body.message_id||''))return reply({ok:false},400);
      const d=await rpc('get_briefing_push_dispatch',{p_message_id:body.message_id});if(!d.ok)return reply({ok:false},404);
      if(env('PUSH_DELIVERY_ENABLED')!=='true')return reply({ok:false,code:'not_enabled'},503);
      if(!Array.isArray(d.recipient_topics)||d.recipient_topics.some(t=>typeof t!=='string'||!topicPattern.test(t)))throw Error('invalid_routing');
      const topics=[...new Set(d.recipient_topics)],devices=topics.length?await rpc('resolve_native_push_targets',{p_topics:topics}):[];
      if(!Array.isArray(devices))throw Error('invalid_routing');
      const targets=topics.map(topic=>({topic}));for(const device of devices){if(!device.token)continue;if(!topics.includes(device.topic)||!uuid.test(device.device_id||'')||typeof device.token!=='string'||device.token.length>4096)throw Error('invalid_routing');targets.push(device);}
      let failed=0,sent=0;
      for(let i=0;i<targets.length;i+=8){const results=await Promise.allSettled(targets.slice(i,i+8).map(t=>{
        const mode=d.recipient_modes?.[t.topic]||'normal';if(!['weak','normal','strong','urgent'].includes(mode))throw Error('invalid_mode');
        return send(t.topic,{alertId:String(d.message_id),message:preview(d.message),mode,priority:mode==='urgent'?'urgent':'normal',messageType:'general',senderLabel:d.sender_label||'메시지 브리핑'},d.message_id,false,t.token?t:null);
      }));for(const r of results)if(r.status==='rejected')failed++;else sent++;}
      return reply({ok:failed===0,sent,failed},failed?502:200);
    }catch{return reply({ok:false,message:'브리핑은 저장됐지만 일부 알림 발송을 확인하지 못했습니다.'},503);}
  };
}
