// Supabase owns authorization, message storage, routing and delivery records.
// Google FCM is only the native notification transport. No Firebase database/Auth.
const origins = new Set(['https://omgworks24.com', 'https://www.omgworks24.com', 'https://omgseoul.github.io']);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const topicPattern = /^property_[0-9]+_(?:staff|employee_[0-9a-f-]{36}|owner_[0-9a-f-]{36})$/i;
const encoder = new TextEncoder();
function base64url(bytes) { return btoa(String.fromCharCode(...bytes)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_'); }
function preview(text) { return [...String(text || '메세지')].slice(0, 650).join(''); }

export function createNotificationHandler({ env, fetcher = fetch, cryptoApi = crypto, now = () => Date.now() }) {
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
  async function send(topic, data, deliveryId, validateOnly = false) {
    if (!topicPattern.test(topic)) throw new Error('invalid_topic');
    // Obtain transport authorization before taking a delivery lease.
    const bearer = await oauth();
    const deliveryKey = deliveryId + ':' + topic;
    const lease = validateOnly ? { claimed: true } : await rpc('claim_push_delivery', { p_key: deliveryKey });
    if (!lease.claimed) {
      if (lease.status === 'sent') return 'duplicate';
      throw new Error('delivery_in_progress');
    }
    let accepted = false;
    try {
      const response = await fetcher('https://fcm.googleapis.com/v1/projects/guesthouse-manager-ajh/messages:send', {
        method: 'POST', headers: { Authorization: 'Bearer ' + bearer, 'Content-Type': 'application/json' },
        body: JSON.stringify({ validate_only: validateOnly, message: { topic, data,
          android: { priority: 'high', ttl: data.mode === 'stop' ? '60s' : data.mode === 'urgent' ? '300s' : '3600s' } } }),
        signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) {
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
  return async function handle(req) {
    const origin = req.headers.get('origin'), headers = { 'Content-Type': 'application/json', Vary: 'Origin' };
    if (origin && origins.has(origin)) headers['Access-Control-Allow-Origin'] = origin;
    const reply = (body, status = 200) => new Response(JSON.stringify(body), { status, headers });
    if (origin && !origins.has(origin)) return reply({ ok: false, code: 'origin_denied' }, 403);
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: { ...headers,
      'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'content-type, apikey, authorization, x-webhook-secret' } });
    if (req.method !== 'POST') return reply({ ok: false, code: 'method_not_allowed' }, 405);
    try {
      const raw = await req.text();
      if (encoder.encode(raw).length > 16000) return reply({ ok: false, code: 'payload_too_large' }, 413);
      let body; try { body = JSON.parse(raw); } catch { return reply({ ok: false, code: 'invalid_json' }, 400); }
      if (!body || typeof body !== 'object' || Array.isArray(body)) return reply({ ok: false, code: 'invalid_body' }, 400);
      const path = new URL(req.url).pathname;
      // A transport-only validation call never produces a device notification.
      if (path.endsWith('/validate')) {
        const secret = env('PUSH_ADMIN_SECRET');
        if (!secret || req.headers.get('x-webhook-secret') !== secret) return reply({ ok: false, code: 'unauthorized' }, 401);
        await send('property_0_staff', { mode: 'message', message: 'validation' }, 'validation', true);
        return reply({ ok: true, validated: true });
      }
      let payload, topics, deliveryId;
      if (path.endsWith('/telegram')) {
        const secret = env('TELEGRAM_URGENT_SECRET');
        if (!secret || req.headers.get('x-webhook-secret') !== secret) return reply({ ok: false, code: 'unauthorized' }, 401);
        const source = body.message && typeof body.message === 'object' ? body.message : {};
        const text = String(body.text || body.message_text || (typeof body.message === 'string' ? body.message : source.text) || '').trim();
        if (!text.startsWith('!!')) return reply({ ok: true, ignored: true });
        const property = String(body.property_id || body.propertyId || '').trim();
        if (!/^[0-9]+$/.test(property)) return reply({ ok: false, code: 'invalid_property' }, 400);
        const external = body.update_id ?? (source.chat?.id && source.message_id ? source.chat.id + ':' + source.message_id : null);
        if (external == null || String(external).length > 120) return reply({ ok: false, code: 'external_id_required' }, 400);
        const mode = text.startsWith('!!정지') ? 'stop' : text.startsWith('!!테스트') ? 'test' : 'urgent';
        if (env('PUSH_DELIVERY_ENABLED') !== 'true') return reply({ ok: false, code: 'not_enabled' }, 503);
        credentials();
        let id = 'telegram:' + property + ':' + external;
        if (mode === 'urgent') {
          const saved = await rpc('save_telegram_urgent_message_service', { p_management_number: property,
            p_message: text.slice(2).trim() || '긴급 메세지', p_external_id: 'property:' + property + ':' + external });
          if (!saved.ok) return reply({ ok: false, code: saved.code || 'save_failed' }, 400);
          id = saved.message_id;
        }
        deliveryId = id;
        payload = { alertId: String(id), message: mode === 'stop' ? '긴급알림을 중지합니다.' : preview(text.slice(2).trim()),
          mode, priority: mode === 'urgent' ? 'urgent' : 'normal', messageType: 'general', senderLabel: '관리자' };
        topics = ['property_' + property + '_staff'];
      } else {
        if (!uuid.test(body.access_token || '') || !uuid.test(body.message_id || '')) return reply({ ok: false, code: 'invalid_request' }, 400);
        const dispatch = await rpc('get_message_push_dispatch_v2', { p_access_token: body.access_token, p_message_id: body.message_id });
        if (!dispatch.ok) return reply({ ok: false, code: dispatch.code || 'unauthorized' }, 403);
        if (env('PUSH_DELIVERY_ENABLED') !== 'true') return reply({ ok: false, code: 'not_enabled' }, 503);
        credentials();
        deliveryId = dispatch.message_id;
        payload = { alertId: String(dispatch.message_id), message: preview(dispatch.message),
          mode: dispatch.priority === 'urgent' ? 'urgent' : 'message', priority: String(dispatch.priority || 'normal'),
          messageType: String(dispatch.message_type || 'general'), senderLabel: String(dispatch.sender_label || '메세지') };
        topics = dispatch.recipient_topics;
        if (!Array.isArray(topics) || topics.some(t => typeof t !== 'string' || !topicPattern.test(t))) throw new Error('invalid_routing');
      }
      const targets = [...new Set(topics)];
      let sent = 0, duplicates = 0, failed = 0;
      // Bounded concurrency, preserving successful per-recipient deliveries on retry.
      for (let i = 0; i < targets.length; i += 8) {
        const results = await Promise.allSettled(targets.slice(i, i + 8).map(t => send(t, payload, deliveryId)));
        for (const result of results) {
          if (result.status === 'rejected') failed++;
          else if (result.value === 'duplicate') duplicates++;
          else sent++;
        }
      }
      return reply({ ok: failed === 0, sent, duplicates, failed, message_id: deliveryId,
        ...(failed ? { message: '메세지는 저장됐지만 일부 알림 발송을 확인하지 못했습니다.' } : {}) }, failed ? 502 : 200);
    } catch (error) {
      // Never return provider bodies, access tokens, or service-account values.
      return reply({ ok: false, code: error.message === 'not_configured' ? 'not_configured' : 'delivery_failed',
        message: '메세지는 저장됐지만 알림 발송을 확인하지 못했습니다.' }, 503);
    }
  };
}
