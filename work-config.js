(function () {
  const fieldGroups = {
    clock_in: [
      { key: "clean_rooms", label: "청소할 객실", help: "오늘 청소할 객실을 선택합니다." },
      { key: "inspect_rooms", label: "점검할 객실", help: "청소하지 않지만 확인할 객실을 선택합니다." },
      { key: "no_show", label: "노쇼", help: "노쇼가 발생한 객실을 선택합니다." },
      { key: "bedding_stain", label: "침구류 오염", help: "오염된 침구류가 있는 객실을 선택합니다." }
    ],
    clock_out: [
      { key: "cleaned_rooms", label: "청소 완료 객실", help: "청소를 완료한 객실을 선택합니다." },
      { key: "inspected_rooms", label: "점검 완료 객실", help: "점검을 완료한 객실을 선택합니다." }
    ]
  };
  const defaults = {
    clock_in: fieldGroups.clock_in.map(field => field.key),
    clock_out: fieldGroups.clock_out.map(field => field.key)
  };

  function normalizeReportConfig(config) {
    const result = {};
    for (const type of ["clock_in", "clock_out"]) {
      const allowed = new Set(fieldGroups[type].map(field => field.key));
      result[type] = Array.isArray(config?.[type])
        ? [...new Set(config[type].filter(key => allowed.has(key)))]
        : [...defaults[type]];
    }
    return result;
  }

  async function rpc(name, args) {
    const { data, error } = await window.omgSupabase.rpc(name, args);
    if (error || !data?.ok) {
      throw new Error(data?.message || "설정을 불러오지 못했습니다. 연결을 확인해주세요.");
    }
    return data;
  }

  window.omgWorkConfig = {
    fieldGroups,
    defaults,
    normalizeReportConfig,
    async loadLoginProperty() {
      return rpc("get_login_property", {
        p_business_code: window.OMG_SUPABASE.businessCode,
        p_property_code: window.OMG_SUPABASE.propertyCode
      });
    },
    async load(accessToken) {
      const data = await rpc("get_work_app_config", { p_access_token: accessToken });
      data.report_config = normalizeReportConfig(data.report_config);
      if (Array.isArray(data.employees)) {
        data.employees = data.employees.map(employee => ({
          ...employee,
          report_config: normalizeReportConfig(employee.report_config)
        }));
      }
      return data;
    },
    async save(accessToken, propertyName, rooms, employeeConfigs) {
      return rpc("save_property_settings", {
        p_access_token: accessToken,
        p_property_name: propertyName,
        p_rooms: rooms,
        p_employee_configs: employeeConfigs
      });
    }
  };
})();
