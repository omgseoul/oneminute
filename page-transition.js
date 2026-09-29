(function () {
  const root = document.documentElement;
  let brandTimer = 0;

  function scheduleBrand() {
    clearTimeout(brandTimer);
    brandTimer = setTimeout(function () {
      if (root.classList.contains("omg-booting") || root.classList.contains("omg-leaving")) {
        root.classList.add("omg-brand");
      }
    }, 180);
  }

  function ready() {
    clearTimeout(brandTimer);
    root.classList.remove("omg-brand", "omg-booting", "omg-leaving");
    root.classList.add("omg-revealing");
    setTimeout(function () { root.classList.remove("omg-revealing"); }, 190);
  }

  function leave() {
    root.classList.remove("omg-revealing");
    root.classList.add("omg-leaving");
    scheduleBrand();
  }

  window.omgTransition = { ready: ready, leave: leave };
  scheduleBrand();

  // Keep anchor navigation native. Cancelling clicks and scheduling location.assign
  // in requestAnimationFrame can strand navigation inside Android WebView.
  // The destination page owns its entry transition; outgoing links need no mask.

  addEventListener("pageshow", function () {
    if (root.classList.contains("omg-leaving")) ready();
  });

  if (root.dataset.omgReady !== "manual") {
    addEventListener("DOMContentLoaded", ready, { once: true });
  } else {
    setTimeout(function () {
      if (root.classList.contains("omg-booting") && !document.getElementById("appShell")) ready();
    }, 8000);
  }
})();

(function () {
  // Native WebView only: ordinary browser links keep their default behavior.
  if (!window.OMGNative || window.omgTapRecoveryInstalled) return;
  window.omgTapRecoveryInstalled = true;
  var pending = null, timer = 0, attempt = 0, down = null;
  function cancel() { clearTimeout(timer); pending = null; }
  function menuLink(target) {
    var link = target && target.closest ? target.closest('a[href]') : null;
    if (!link || link.target || link.hasAttribute('download') || link.getAttribute('href').charAt(0) === '#') return null;
    var url = new URL(link.href, location.href);
    return /^https?:$/.test(url.protocol) && url.origin === location.origin ? link : null;
  }
  function showFailure(link, code) {
    if (document.getElementById('navigationFailure')) return;
    var layer = document.createElement('div');
    layer.id = 'navigationFailure';
    layer.setAttribute('role', 'dialog');
    layer.setAttribute('aria-modal', 'true');
    layer.setAttribute('aria-labelledby', 'navigationFailureTitle');
    layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:22px;background:rgba(17,34,56,.46)';
    layer.innerHTML = '<section style="width:min(100%,350px);box-sizing:border-box;padding:24px;border-radius:25px;background:white;color:#183153;box-shadow:0 18px 45px #18315340"><h2 id="navigationFailureTitle" style="margin:0 0 12px;font-size:21px">화면 이동을 확인해주세요</h2><p style="font-size:15px;line-height:1.6">메뉴 이동을 완료하지 못했습니다.<br>아래 진단 내용을 화면으로 보내주세요.</p><p data-nav-code style="padding:12px;background:#f4f7fc;border-radius:12px;font-size:13px;overflow-wrap:anywhere"></p><div style="display:flex;gap:10px"><button type="button" data-nav-close style="flex:1;padding:13px;border:0;border-radius:13px;background:#eaf2ff;color:#183153;font:inherit">닫기</button><button type="button" data-nav-retry style="flex:1;padding:13px;border:0;border-radius:13px;background:#2467bd;color:white;font:inherit">다시 이동</button></div></section>';
    // Only engine version and page path; never include session tokens or messages.
    var engine = (navigator.userAgent.match(/Chrome\/([\d.]+)/) || [])[1] || 'unknown';
    layer.querySelector('[data-nav-code]').textContent = 'N5 · ' + code + ' · WebView ' + engine + ' · ' + new URL(link.href).pathname;
    layer.querySelector('[data-nav-close]').onclick = function () { layer.remove(); cancel(); };
    layer.querySelector('[data-nav-retry]').onclick = function () { layer.remove(); location.assign(link.href); };
    document.body.appendChild(layer);
    layer.querySelector('[data-nav-close]').focus();
  }
  document.addEventListener('pointerdown', function (event) {
    var link = menuLink(event.target);
    down = link && event.isPrimary !== false && event.button === 0 ? {link:link,x:event.clientX,y:event.clientY,time:Date.now(),id:event.pointerId} : null;
  }, true);
  document.addEventListener('pointermove', function (event) {
    if (down && (event.pointerId !== down.id || Math.hypot(event.clientX-down.x,event.clientY-down.y) > 10)) down = null;
  }, true);
  document.addEventListener('scroll', function () { down = null; cancel(); }, true);
  document.addEventListener('contextmenu', function () { down = null; cancel(); }, true);
  document.addEventListener('pointercancel', function () { down = null; }, true);
  document.addEventListener('pointerup', function (event) {
    var start = down; down = null;
    if (!start || event.pointerId !== start.id || Date.now()-start.time > 700 || menuLink(event.target) !== start.link || Math.hypot(event.clientX-start.x,event.clientY-start.y) > 10) return;
    cancel(); pending = start.link;
    // Let a normal click win first; recover a completed tap if WebView drops it.
    timer = setTimeout(function () {
      if (pending !== start.link) return;
      location.assign(start.link.href);
      timer = setTimeout(function () { if (pending === start.link) showFailure(start.link, '터치 직접 이동 미완료'); }, 5000);
    }, 400);
  }, true);
  document.addEventListener('click', function (event) {
    var link = menuLink(event.target);
    if (!link || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    cancel(); pending = link;
    var id = ++attempt;
    // Do not cancel the real click. Retry only if this document never leaves.
    timer = setTimeout(function () {
      if (pending !== link || id !== attempt) return;
      location.assign(link.href);
      timer = setTimeout(function () { if (pending === link && id === attempt) showFailure(link, '클릭 후 이동 미완료'); }, 5000);
    }, 1500);
  }, true);
  addEventListener('pagehide', cancel);
  addEventListener('pageshow', cancel);
})();
