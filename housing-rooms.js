window.OMSHousingRooms = (() => {
  const houseLabel = value => String(value || '').replace(/\s+/g, ' ').trim();
  function houseName(value) { const text=houseLabel(value),label=document.createElement('span');label.className='entire-house-name';label.textContent=text;label.title=text;return label; }
  const housesFor = groups => (groups || []).filter(group => !(group.rooms || []).length).map(group => group.name).filter(Boolean);
  function append(parent, field, groups, onChange) {
    let houseList = null;
    (groups || []).forEach((group, groupIndex) => {
      const isHouse = !(group.rooms || []).length;
      let list;
      if (isHouse && houseList) list = houseList;
      else {
        const block = document.createElement('div');
        block.className = 'room-group' + (isHouse ? ' entire-house-group' : '');
        const type = document.createElement('p'); type.className = 'room-type';
        if (isHouse) type.setAttribute('aria-hidden', 'true'); else type.textContent = group.name;
        list = document.createElement('div'); list.className = isHouse ? 'rooms entire-house-options' : 'rooms';
        block.append(type, list); parent.append(block);
        houseList = isHouse ? list : null;
      }
      (isHouse ? [group.name] : group.rooms).forEach((room, index) => {
        const wrap = document.createElement('span'); wrap.className = 'room' + (isHouse ? ' entire-house-choice' : '');
        const input = document.createElement('input'); input.type = 'checkbox'; input.name = field.key;
        input.value = room; input.id = `${field.key}-${groupIndex}-${index}`;
        if (onChange) input.addEventListener('change', onChange);
        const label = document.createElement('label'); label.htmlFor = input.id; if(isHouse){label.title=houseLabel(room);label.append(houseName(room));}else label.textContent = room;
        wrap.append(input, label); list.append(wrap);
      });
    });
  }
  function result(values, houses) {
    const host = document.createElement('div'); host.className = 'housing-result';
    const houseNames = new Set(houses || []), grid = document.createElement('div'); grid.className = 'entire-house-results';
    const units = [];
    (values || []).forEach(value => {
      if (!houseNames.has(value)) { units.push(value); return; }
      const chip = document.createElement('span'); chip.className = 'entire-house-result'; chip.title=houseLabel(value);chip.append(houseName(value));grid.append(chip);
    });
    if (grid.childElementCount) host.append(grid);
    if (units.length || !grid.childElementCount) {
      const text = document.createElement('span'); text.className = 'housing-unit-result';
      text.textContent = units.length ? `${units.length}건 ${units.join(', ')}` : '없음'; host.append(text);
    }
    return host.outerHTML;
  }
  return {append, result, housesFor};
})();
