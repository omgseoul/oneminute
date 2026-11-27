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
  async function request(session, preference, feed = false) {
    const {data, error} = await omgSupabase.rpc('oms_home_display', {
      p_access_token: session.accessToken,
      p_preferences: preference || null,
      p_feed: feed
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
    for (const input of categoryFields.querySelectorAll('input')) input.checked = data.categories.includes(input.value);
    render();
    form.hidden = false;
    form.onsubmit = async event => {
      event.preventDefault();
      const button = form.querySelector('button');
      button.disabled = true;
      try {
        await request(session, {sections:order, categories:[...categoryFields.querySelectorAll('input:checked')].map(input => input.value)});
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
    const letters = typeof Intl.Segmenter === 'function'
      ? Array.from(new Intl.Segmenter('ko').segment(name), part => part.segment)
      : Array.from(name);
    const shortName = letters.length > 8 ? letters.slice(0, 5).join('') + '...' : name;
    const arrival = stayDate(item.arrival), departure = stayDate(item.departure);
    const dates = arrival && departure ? arrival + '-' + departure : '';
    const kind = eventLabels[item.kind] || '이벤트';
    const time = document.createElement('time');
    time.dateTime = item.at_time;
    time.textContent = clock.format(new Date(item.at_time));
    link.href = eventLink(item, property);
    link.title = [item.property_name, kind, name, dates, item.channel, time.textContent].filter(Boolean).join(' · ');
    link.append(field('home-event-property', item.property_name || ''), field('home-event-kind', kind), field('home-event-name', shortName));
    if (dates) link.append(field('home-event-stay', dates));
    if (item.channel && window.OMSGuestMessageCard) link.append(OMSGuestMessageCard.channelIcon(item.channel));
    link.append(time);
    return link;
  }

  async function mount(session) {
    const staff = byId('homeStaffDisplay'), events = byId('homeEventsDisplay'), list = byId('homeEventsList');
    if (!staff || !events || session.sessionKind !== 'owner') return;
    let busy = false, signature = '';
    async function refresh() {
      if (busy || document.hidden) return;
      busy = true;
      try {
        const data = await request(session, null, true);
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
        const clock = new Intl.DateTimeFormat('ko-KR', {
          timeZone:session.timezone || 'Asia/Seoul', hour:'2-digit', minute:'2-digit', hourCycle:'h23'
        });
        const rows = data.events.map(item => eventRow(item, data.property_id, clock));
        const position = list.scrollTop;
        list.replaceChildren(...rows);
        if (!rows.length) list.textContent = '최근 이벤트가 없습니다.';
        list.scrollTop = position;
      } finally { busy = false; }
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
