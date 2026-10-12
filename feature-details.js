(() => {
  'use strict';
  const tabs = [...document.querySelectorAll('[role="tab"][data-panel]')];
  function activate(tab) {
    tabs.forEach(item => {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
      document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
    });
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => activate(tab));
    tab.addEventListener('keydown', event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      activate(tabs[next]);
      tabs[next].focus();
    });
  });
  const complete = document.querySelector('.demo-complete');
  complete?.addEventListener('click', () => {
    complete.hidden = true;
    document.querySelector('.completion-result').hidden = false;
  });
  const photo = document.getElementById('photo-demo');
  if (photo) {
    const scroll = photo.querySelector('.photo-scroll');
    const zoom = document.getElementById('zoom-demo');
    document.querySelector('.report-photo').addEventListener('click', () => photo.showModal());
    document.getElementById('close-photo').addEventListener('click', () => photo.close());
    zoom.addEventListener('click', () => {
      const enlarged = scroll.classList.toggle('is-zoomed');
      zoom.textContent = enlarged ? '축소 −' : '확대 +';
      zoom.setAttribute('aria-label', enlarged ? '사진 축소' : '사진 확대');
    });
    photo.addEventListener('close', () => {
      scroll.classList.remove('is-zoomed');
      scroll.scrollTo(0, 0);
      zoom.textContent = '확대 +';
      zoom.setAttribute('aria-label', '사진 확대');
    });
  }
})();
