(() => {
  const categoryLabels = {
    ai: 'AI 자동답변 건',
    booking: '예약 발생',
    cancel: '취소 발생',
    attendance: '직원 근태 (출퇴근)'
  };
  const eventLabels = {
    online_ai: 'AI 자동답변', qr_ai: 'AI 자동답변',
    booking: '예약', cancel: '취소', checkin: '출근', checkout: '퇴근'
  };
  const byId = id => document.getElementById(id);
  async function request(session, preference, feed = false, propertyIds = null) {
    const {data, error} = await omgSupabase.rpc('oms_home_display_v2', {
      p_access_token: session.accessToken,
      p_preferences: preference || null,
      p_feed: feed,
      p_property_ids: propertyIds
    });
    if (error || !data?.ok) throw Error(data?.message || '홈화면 정보를 불러오지 못했습니다.');
    return data;
  }

  async function settings(form) {
    const session = await omgSession.require({allowCompleted:true});
    if (!session || session.sessionKind !== 'owner') {
      location.replace('app.html');
      return;
    }
    const sectionFields = [...form.querySelectorAll('[data-home-section]')];
    const categoryFields = byId('homeEventCategories');
    const status = byId('homeDisplayStatus');
    const today = byId('homeTodayVisible'), help = byId('homeTodayHelp'), description = byId('homeTodayDescription');
    help.onclick = () => {
      description.hidden = !description.hidden;
      help.setAttribute('aria-expanded', String(!description.hidden));
    };
    let order = [];
    for (const [key, label] of Object.entries(categoryLabels)) {
      const field = document.createElement('label');
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.value = key;
      field.append(input, label);
      categoryFields.append(field);
    }
    function render() {
      for (const input of sectionFields) {
        const index = order.indexOf(input.value);
        input.checked = index >= 0;
        input.closest('label').querySelector('output').textContent = index < 0 ? '' : String(index + 1);
      }
      categoryFields.hidden = !order.includes('events');
    }
    for (const input of sectionFields) input.onchange = () => {
      order = order.filter(key => key !== input.value);
      if (input.checked) order.push(input.value);
      render();
    };
    const data = await request(session);
    order = data.sections;
    today.checked = data.today_visible !== false;
    for (const input of categoryFields.querySelectorAll('input')) input.checked = data.categories.includes(input.value);
    render();
    form.hidden = false;
    form.onsubmit = async event => {
      event.preventDefault();
      const button = form.querySelector('button[type=submit]');
      button.disabled = true;
      try {
        await request(session, {sections:order, today_visible:today.checked, categories:[...categoryFields.querySelectorAll('input:checked')].map(input => input.value)});
        status.textContent = '저장했습니다.';
      } catch (error) { status.textContent = error.message; }
      finally { button.disabled = false; }
    };
  }

  function eventLink(item, property) {
    const target = encodeURIComponent(item.target), branch = encodeURIComponent(property);
    if (item.kind === 'booking' || item.kind === 'cancel') return 'online.html#booking-data?property='+branch+'&booking='+target+(item.booking_day?'&day='+encodeURIComponent(item.booking_day):'');
    if (item.kind === 'online_ai') return 'guest-messages.html#thread/'+target+'?property='+branch;
    if (item.kind === 'qr_ai') return 'guest-chat.html?room='+target;
    return 'messages.html?tab=reports';
  }

  function stayDate(value) {
    const date = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
    return date ? date[2] + '/' + date[3] : '';
  }

  function eventRow(item, property, clock) {
    const link = document.createElement('a');
    const field = (className, value) => {
      const span = document.createElement('span');
      span.className = className;
      span.textContent = value;
      return span;
    };
    const name = item.label || '이름 미등록';
    const arrival = stayDate(item.arrival), departure = stayDate(item.departure);
    const dates = arrival && departure ? arrival + '-' + departure : '';
    const kind = eventLabels[item.kind] || '이벤트';
    const time = document.createElement('time');
    time.dateTime = item.at_time;
    time.textContent = clock.format(new Date(item.at_time));
    link.href = eventLink(item, property);
    link.title = [item.property_name, kind, name, dates, item.channel, time.textContent].filter(Boolean).join(' · ');
    link.append(field('home-event-property', item.property_name || ''), field('home-event-kind', kind), field('home-event-name', name));
    if (dates) link.append(field('home-event-stay', dates));
    if (item.channel && window.OMSGuestMessageCard) link.append(OMSGuestMessageCard.channelIcon(item.channel));
    link.append(time);
    return link;
  }

  async function mount(session) {
    const staff = byId('homeStaffDisplay'), events = byId('homeEventsDisplay'), list = byId('homeEventsList');
    if (!staff || !events || session.sessionKind !== 'owner') return;
    const today = byId('todayOverview'), pickerHost = byId('homeEventPicker');
    const selectionKey = 'oms:home-event-branches:' + (session.ownerId || '') + ':' + (session.propertyId || '');
    let selected = null;
    try {
      const saved = JSON.parse(localStorage.getItem(selectionKey));
      if (Array.isArray(saved) && saved.every(id => typeof id === 'string')) selected = saved;
    } catch { /* User may block local storage. */ }
    let busy = false, queued = false, signature = '', picker = null, branchSignature = '';
    function renderPicker(branches, ownProperty) {
      if (!pickerHost || !window.omgPropertySelector?.mountMulti || !branches?.length) return;
      const next = JSON.stringify(branches);
      if (next === branchSignature) return;
      branchSignature = next;
      picker?.destroy();
      const paintBadge = () => {
        const button = picker.root.querySelector('button');
        button.textContent = 'Event';
        button.setAttribute('aria-label', 'Event 지점 선택');
      };
      picker = omgPropertySelector.mountMulti({
        host:pickerHost,
        items:branches.map(b => ({value:b.id, label:b.name})),
        title:'Event 지점',
        allLabel:'전체 지점',
        selectedValues:selected ?? [ownProperty],
        onChange(ids) {
          selected = ids;
          paintBadge();
          try { localStorage.setItem(selectionKey, JSON.stringify(ids)); } catch {}
          update();
        }
      });
      paintBadge();
    }
    async function refresh() {
      if (document.hidden) return;
      if (busy) { queued = true; return; }
      busy = true;
      try {
        const data = await request(session, null, true, selected);
        if (today) today.hidden = data.today_visible === false;
        renderPicker(data.branches, data.property_id);
        const panels = {staff, events};
        const parent = staff.parentElement;
        const currentOrder = [...parent.children].filter(node => node === staff || node === events);
        const desiredOrder = [...data.sections, ...Object.keys(panels).filter(key => !data.sections.includes(key))].map(key => panels[key]);
        if (desiredOrder.some((panel,index) => panel !== currentOrder[index])) parent.append(...desiredOrder);
        staff.hidden = !data.sections.includes('staff');
        events.hidden = !data.sections.includes('events');
        const next = JSON.stringify(data.events);
        if (next === signature) return;
        signature = next;
        const clocks = new Map();
        const rows = data.events.map(item => {
          const zone = item.timezone || session.timezone || 'Asia/Seoul';
          if (!clocks.has(zone)) clocks.set(zone, new Intl.DateTimeFormat('ko-KR', {
            timeZone:zone, hour:'2-digit', minute:'2-digit', hourCycle:'h23'
          }));
          return eventRow(item, item.property_id || data.property_id, clocks.get(zone));
        });
        const position = list.scrollTop;
        list.replaceChildren(...rows);
        if (!rows.length) list.textContent = '최근 이벤트가 없습니다.';
        list.scrollTop = position;
      } finally { busy = false; if (queued) { queued = false; update(); } }
    }
    const update = () => refresh().catch(() => {});
    addEventListener('pageshow', update);
    document.addEventListener('visibilitychange', update);
    setInterval(update, 45000);
    await refresh();
  }
  window.OMSHomeDisplay = {mount};
  const form = byId('homeDisplayForm');
  if (form) settings(form).catch(error => { byId('homeDisplayStatus').textContent = error.message; });
})();
