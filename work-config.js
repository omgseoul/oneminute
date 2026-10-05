(function () {
  const reportFields = [];
  const fieldGroups = {
    clock_in: reportFields,
    clock_out: reportFields
  };
  const defaults = {
    clock_in: [],
    clock_out: [],
    reminder_cards: [
      {
        id: "watch",
        title: "워치 착용",
        image: "directive-watch.png",
        text: "출근 즉시 워치 착용.\n절대 빼지 마세요. 방수임.\n게하폰과 5미터 이내에 있어야 작동합니다.",
        report_types: ["clock_in"],
        report_weekdays: { clock_in: [0, 1, 2, 3, 4, 5, 6] },
        weekdays: [0, 1, 2, 3, 4, 5, 6]
      },
      {
        id: "guest-guide",
        title: "게스트 직접 안내",
        image: "directive-guest-guide.jpg",
        text: "짐을 들어주고 문 앞까지 갈 것.\n도어락과 카드키 설명.\n앉아서 말로만 안내하는 건 퇴사 사유임.",
        report_types: ["clock_in"],
        report_weekdays: { clock_in: [0, 1, 2, 3, 4, 5, 6] },
        weekdays: [0, 1, 2, 3, 4, 5, 6]
      },
      {
        id: "carry-devices",
        title: "게하폰·워치 항상 소지",
        image: "shiba-worker-logo-v2.png",
        text: "워치와 게하폰을 책상 위에 두고 청소하지 마세요.\n알람을 놓치지 않도록 근무 중 항상 몸에 소지합니다.",
        report_types: ["clock_in"],
        report_weekdays: { clock_in: [0, 1, 2, 3, 4, 5, 6] },
        weekdays: [0, 1, 2, 3, 4, 5, 6]
      },
      {
        id: "final-check",
        title: "객실 최종 확인",
        image: "shiba-cleaner-logo.png",
        text: "객실을 나오기 전에 비품, 도어락, 조명, 냉난방 상태를 마지막으로 확인합니다.",
        report_types: ["clock_in"],
        report_weekdays: { clock_in: [0, 1, 2, 3, 4, 5, 6] },
        weekdays: [0, 1, 2, 3, 4, 5, 6]
      }
    ]
  };

  function normalizeCustomFields(fields) {
    const seen = new Set();
    return (Array.isArray(fields) ? fields : []).slice(0, 20).map(field => ({
      key: String(field?.key || "").trim().slice(0, 57),
      label: String(field?.label || "").trim().slice(0, 40),
      help: "",
      kind: ["text", "numeric", "counter", "rooms", "photo"].includes(field?.kind) ? field.kind : "text",
      size: field?.size === "half" ? "half" : "full",
      required: field?.required === true,
      custom: true
    })).filter(field => /^custom_[a-z0-9_-]{1,50}$/.test(field.key) && field.label && !seen.has(field.key) && seen.add(field.key));
  }

  function fieldsFor(property) {
    const custom = normalizeCustomFields(property?.custom_report_fields);
    return custom;
  }

  function normalizeReportConfig(config, property) {
    const result = {};
    const customKeys = normalizeCustomFields(property?.custom_report_fields).map(field => field.key);
    for (const type of ["clock_in", "clock_out"]) {
      const allowed = new Set([...fieldGroups[type].map(field => field.key), ...customKeys, "reminder_cards"]);
      result[type] = Array.isArray(config?.[type])
        ? [...new Set(config[type].filter(key => allowed.has(key)))]
        : [...defaults[type]];
    }
    const legacyReportTypes = ["clock_in", "clock_out"].filter(type => result[type].includes("reminder_cards"));
    const normalizeWeekdays = value => Array.isArray(value)
      ? [...new Set(value.map(Number).filter(day => Number.isInteger(day) && day >= 0 && day <= 6))]
      : [0, 1, 2, 3, 4, 5, 6];
    result.reminder_cards = Array.isArray(config?.reminder_cards)
      ? config.reminder_cards.slice(0, 12).map((card, index) => ({
          id: String(card?.id || `card-${index + 1}`).slice(0, 50),
          title: String(card?.title || "리마인더").slice(0, 50),
          image: String(card?.image || "").slice(0, 900000),
          text: String(card?.text || "").slice(0, 1000),
          report_types: Array.isArray(card?.report_types)
            ? [...new Set(card.report_types.filter(type => type === "clock_in" || type === "clock_out"))]
            : [...legacyReportTypes],
          report_weekdays: Object.fromEntries(["clock_in", "clock_out"].filter(type =>
            Array.isArray(card?.report_weekdays?.[type]) || legacyReportTypes.includes(type)
          ).map(type => [type, normalizeWeekdays(card?.report_weekdays?.[type] ?? card?.weekdays)])),
          weekdays: normalizeWeekdays(card?.weekdays)
        })).filter(card => card.title && card.image && card.text)
      : defaults.reminder_cards.map(card => ({ ...card }));
    return result;
  }

  function normalizeRoomTypes(roomTypes, rooms) {
    const source = Array.isArray(roomTypes) && roomTypes.length
      ? roomTypes
      : [{ name: "객실", rooms: Array.isArray(rooms) ? rooms : [] }];
    return source.slice(0, 30).map((group, index) => ({
      name: String(group?.name || `객실타입${index + 1}`).trim().slice(0, 40),
      rooms: [...new Set((Array.isArray(group?.rooms) ? group.rooms : []).map(room => String(room).trim()).filter(Boolean))].slice(0, 100)
    })).filter(group => group.name && group.rooms.length);
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
    fieldsFor,
    orderedFields(property, keys) { const fields = new Map(fieldsFor(property).map(field => [field.key, field])); return (keys || []).map(key => fields.get(key)).filter(Boolean); },
    normalizeCustomFields,
    defaults,
    normalizeReportConfig,
    async loadLoginProperty() {
      return rpc("get_login_property", {
        p_business_code: window.OMG_SUPABASE.businessCode,
        p_property_code: window.OMG_SUPABASE.propertyCode
      });
    },
    async load(accessToken, propertyId, scope) {
      const data = await rpc(propertyId ? "shared_get_work_app_config" : "get_work_app_config", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId,p_scope:scope} : {}) });
      data.property.business_type = ["lodging", "general", "other"].includes(data.property.business_type) ? data.property.business_type : null;
      data.property.custom_report_fields = normalizeCustomFields(data.property.custom_report_fields);
      data.report_config = normalizeReportConfig(data.report_config, data.property);
      data.property.room_types = normalizeRoomTypes(data.property.room_types, data.property.rooms);
      if (Array.isArray(data.employees)) {
        data.employees = data.employees.map(employee => ({
          ...employee,
          report_config: normalizeReportConfig(employee.report_config, data.property)
        }));
      }
      return data;
    },
    async save(accessToken, propertyName, businessType, roomTypes, customFields, employeeConfigs, propertyId) {
      const normalizedRoomTypes = businessType === "lodging" ? normalizeRoomTypes(roomTypes) : [];
      return rpc(propertyId ? "shared_save_property_settings" : "save_property_settings", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}),
        p_property_name: propertyName,
        p_rooms: normalizedRoomTypes.flatMap(group => group.rooms),
        p_room_types: normalizedRoomTypes,
        p_business_type: businessType || null,
        p_custom_report_fields: normalizeCustomFields(customFields).map(({ key, label, kind, size, required }) => ({ key, label, kind, size, required })),
        p_employee_configs: employeeConfigs
      });
    },
    normalizeRoomTypes,
    async saveNotice(accessToken, notice, propertyId) {
      return rpc(propertyId ? "shared_save_property_notice" : "save_property_notice", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_notice: notice });
    },
    async saveEmployees(accessToken, employees, propertyId) {
      return rpc(propertyId ? "shared_save_employee_accounts" : "save_employee_accounts", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_employees: employees });
    },
    async loadEmployeeAttendanceSettings(accessToken, propertyId) {
      return rpc(propertyId ? "shared_list_employee_attendance_settings" : "list_employee_attendance_settings", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), });
    },
    async saveEmployeeAttendanceSettings(accessToken, employees, propertyId) {
      return rpc(propertyId ? "shared_save_employee_attendance_settings" : "save_employee_attendance_settings", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_employees: employees });
    },
    async loadAttendanceWarnings(accessToken, propertyId) {
      return rpc(propertyId ? "shared_list_attendance_warning_rules" : "list_attendance_warning_rules", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), });
    },
    async saveAttendanceWarnings(accessToken, rules, propertyId) {
      return rpc(propertyId ? "shared_save_attendance_warning_rules" : "save_attendance_warning_rules", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_rules: rules });
    },
    async deleteEmployee(accessToken, employeeId, propertyId) {
      return rpc(propertyId ? "shared_delete_employee_account" : "delete_employee_account", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_employee_id: employeeId });
    },
    async saveAdministrators(accessToken, administrators, propertyId) {
      return rpc(propertyId ? "shared_save_admin_accounts" : "save_admin_accounts", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_administrators: administrators });
    },
    async deleteAdministrator(accessToken, ownerId, propertyId) {
      return rpc(propertyId ? "shared_delete_admin_account" : "delete_admin_account", { p_access_token: accessToken, ...(propertyId ? {p_property_id:propertyId} : {}), p_owner_id: ownerId });
    }
  };
})();

