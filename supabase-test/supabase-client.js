(function () {
  const config = window.OMG_SUPABASE;

  if (!config || !window.supabase) {
    throw new Error("Supabase client configuration is missing.");
  }

  window.omgSupabase = window.supabase.createClient(
    config.url,
    config.publishableKey,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false
      }
    }
  );

  window.omgSession = {
    key: "omg_preview_work_session",
    get() {
      try {
        return JSON.parse(localStorage.getItem(this.key) || "null");
      } catch (_) {
        return null;
      }
    },
    set(session) {
      localStorage.setItem(this.key, JSON.stringify(session));
    },
    clear() {
      localStorage.removeItem(this.key);
    },
    fromResponse(data, token) {
      return {
        accessToken: token,
        sessionId: data.session_id,
        employeeId: data.employee_id,
        employeeName: data.employee_name,
        role: data.role,
        shift: data.shift,
        clockInAt: data.clock_in_at,
        clockOutAt: data.clock_out_at,
        workDate: data.work_date,
        expiresAt: data.expires_at,
        timezone: data.timezone || "Asia/Seoul",
        status: data.status,
        checkinReportAt: data.checkin_report_at,
        checkoutReportAt: data.checkout_report_at
      };
    },
    async require({ allowCompleted = false } = {}) {
      const session = this.get();
      const tokenPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (!session || !tokenPattern.test(session.accessToken || "")) {
        this.clear();
        location.replace("login.html");
        return null;
      }
      const { data, error } = await window.omgSupabase.rpc("get_work_session", {
        p_access_token: session.accessToken
      });
      if (error) throw new Error("로그인 상태를 확인하지 못했습니다. 연결을 확인하고 새로고침해주세요.");
      if (!data?.ok || (!allowCompleted && data.status !== "working")) {
        this.clear();
        location.replace("login.html");
        return null;
      }
      const verified = this.fromResponse(data, session.accessToken);
      this.set(verified);
      return verified;
    },
    async logout() {
      const session = this.get();
      try {
        if (!session?.accessToken) return true;
        const { data, error } = await window.omgSupabase.rpc("end_device_session", {
          p_access_token: session.accessToken
        });
        return !error && data?.ok === true;
      } catch (_) {
        return false;
      } finally {
        this.clear();
      }
    }
  };
})();
