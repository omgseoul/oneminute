/* Decode a real frame, including MediaRecorder WebM files without a finite duration. */
window.OMSVideoPreview = (() => {
  const pending = []; let active = 0;
  function frame(video) {
    if (video.readyState < 2 || !video.videoWidth || !video.videoHeight) return {image:'', visible:false};
    const canvas = document.createElement('canvas');
    canvas.width = Math.min(400, video.videoWidth); canvas.height = Math.max(1, Math.round(canvas.width * video.videoHeight / video.videoWidth));
    const ctx = canvas.getContext('2d', {willReadFrequently:true});ctx.drawImage(video,0,0,canvas.width,canvas.height);
    const pixels=ctx.getImageData(0,0,canvas.width,canvas.height).data;let visible=0;
    for(let i=0;i<pixels.length;i+=64)if(Math.max(pixels[i],pixels[i+1],pixels[i+2])>22)visible++;
    return {image:canvas.toDataURL('image/jpeg',.78),visible:visible>pixels.length/64*.015};
  }
  function decode(url) {
    return new Promise(resolve => {
      const video = document.createElement('video');
      video.muted = true; video.defaultMuted = true; video.playsInline = true; video.preload = 'auto';
      video.setAttribute('muted', ''); video.setAttribute('playsinline', '');
      video.style.cssText = 'position:fixed;left:-10000px;top:0;width:320px;height:180px;opacity:0;pointer-events:none';
      document.body.append(video);
      let done = false, lastImage = '', interval, timeout, startedAt = Date.now(), frameId;
      function finish(image) {
        if (done) return; done = true; clearInterval(interval); clearTimeout(timeout);
        if (frameId != null) video.cancelVideoFrameCallback?.(frameId);
        video.onloadeddata = video.onloadedmetadata = video.onseeked = video.onerror = null;
        video.pause(); video.removeAttribute('src'); video.load(); video.remove(); resolve(image || '');
      }
      function capture() {
        if (done || video.readyState < 2 || !video.videoWidth || !video.videoHeight) return;
        try {
          const result=frame(video);lastImage=result.image;
          if (result.visible) finish(lastImage);
          else if (Date.now() - startedAt > 3000) finish(lastImage);
        } catch (_) { finish(lastImage); }
      }
      function decodedFrame() { capture(); if (!done && video.requestVideoFrameCallback) frameId = video.requestVideoFrameCallback(decodedFrame); }
      video.onloadedmetadata = () => {
        // Seeking also decodes a preview when Android requires a gesture for play().
        try { video.currentTime = Number.isFinite(video.duration) && video.duration > 0 ? Math.min(.2,video.duration/4) : .2; } catch (_) {}
      };
      video.onloadeddata = () => { startedAt = Date.now(); video.play().catch(() => capture()); if (video.requestVideoFrameCallback) frameId = video.requestVideoFrameCallback(decodedFrame); };
      video.onseeked = capture;
      video.onerror = () => finish('');
      interval = setInterval(capture, 160); timeout = setTimeout(() => { capture(); finish(lastImage); }, 12000);
      video.src = url; video.load();
    });
  }
  function pump() {
    while (active < 2 && pending.length) {
      const {url, resolve} = pending.shift(); active++;
      decode(url).then(resolve, () => resolve('')).finally(() => { active--; pump(); });
    }
  }
  return {frame(video){try{const result=frame(video);return result.visible?result.image:'';}catch{return '';}},poster(url) { return new Promise(resolve => { pending.push({url, resolve}); pump(); }); }};
})();
