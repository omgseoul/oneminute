(function () {
  window.omgNotifications = {
    async send(accessToken, messageId, { timeoutMs = 15000 } = {}) {
      const config = window.OMG_NOTIFICATIONS;
      if (!config || !["firebase", "supabase"].includes(config.provider)) throw new Error("알림 설정을 확인해주세요.");
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetch(config.provider === "supabase" ? config.supabaseUrl : config.firebaseUrl, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ access_token: accessToken, message_id: messageId }), signal: controller.signal
        });
        const result = await response.json().catch(() => null);
        if (!response.ok || !result?.ok) throw new Error(result?.message || "메세지는 저장됐지만 알림 발송을 확인하지 못했습니다.");
        return result;
      } finally { clearTimeout(timeout); }
      // Do not retry through another provider after an ambiguous timeout:
      // that could ring the same employee twice.
    }
  };
})();
