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

  document.addEventListener("click", function (event) {
    const link = event.target.closest("a[href]");
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (link.target || link.hasAttribute("download")) return;
    const url = new URL(link.href, location.href);
    if (url.origin !== location.origin || (url.pathname === location.pathname && url.search === location.search && url.hash)) return;
    event.preventDefault();
    leave();
    requestAnimationFrame(function () { location.assign(url.href); });
  });

  addEventListener("pageshow", function () {
    if (root.classList.contains("omg-leaving")) ready();
  });

  if (root.dataset.omgReady !== "manual") {
    addEventListener("DOMContentLoaded", ready, { once: true });
  } else {
    setTimeout(function () {
      if (root.classList.contains("omg-booting")) ready();
    }, 8000);
  }
})();
