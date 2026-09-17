import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

function response(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}

export default {
  async fetch(request: Request) {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return response({ ok: false, message: "POST 요청만 허용됩니다." }, 405);

  try {
    const { access_token, report_id, report_type } = await request.json();
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuid.test(access_token || "") || !uuid.test(report_id || "") || !["clock_in", "clock_out"].includes(report_type)) {
      return response({ ok: false, message: "보고 전송 요청을 확인해주세요." }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const makeWebhookUrl = Deno.env.get("MAKE_REPORT_WEBHOOK_URL");
    if (!supabaseUrl || !anonKey || !makeWebhookUrl) {
      return response({ ok: false, message: "서버 전송 설정이 완료되지 않았습니다." }, 503);
    }

    const supabase = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data: report, error: reportError } = await supabase.rpc("get_work_report", {
      p_access_token: access_token,
      p_report_type: report_type
    });
    if (reportError || !report?.ok || report.report_id !== report_id) {
      return response({ ok: false, message: "저장된 보고를 확인하지 못했습니다." }, 403);
    }
    if (report.make_accepted) return response({ ok: true, already_delivered: true });

    const delivered = await fetch(makeWebhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(report.payload)
    });
    if (!delivered.ok) return response({ ok: false, message: "보고 전달에 실패했습니다." }, 502);

    const { data: acknowledged, error: acknowledgeError } = await supabase.rpc("mark_report_delivered", {
      p_access_token: access_token,
      p_report_id: report_id
    });
    if (acknowledgeError || !acknowledged?.ok) {
      return response({ ok: false, message: "전달 상태를 저장하지 못했습니다." }, 500);
    }
    return response({ ok: true });
  } catch (_) {
    return response({ ok: false, message: "보고 전송 요청을 처리하지 못했습니다." }, 500);
  }
  }
};
