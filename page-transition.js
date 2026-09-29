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
      if (root.classList.contains("omg-booting")) ready();
    }, 8000);
  }
})();
