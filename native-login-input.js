/* Android uses a real EditText for the username so Hangul composition never depends
   on WebView's first input connection. Other browsers retain the ordinary input. */
(function(){
 const bridge=window.OMSLoginInput,input=document.getElementById('employeeLoginId');
 if(!bridge||!input)return;
 const documentId=String(Date.now())+'-'+Math.random();let frame=0,attached=false;
 function refresh(){
  cancelAnimationFrame(frame);frame=requestAnimationFrame(()=>{
   const r=input.getBoundingClientRect(),v=window.visualViewport;
   const visible=!input.disabled&&r.width>0&&r.height>0&&getComputedStyle(input).visibility!=='hidden'&&r.bottom>0&&r.top<(v?.height||innerHeight);
   bridge.layout(JSON.stringify({documentId,visible,x:r.left-(v?.offsetLeft||0),y:r.top-(v?.offsetTop||0),width:r.width,height:r.height,viewportWidth:v?.width||innerWidth,value:input.value,fontSize:parseFloat(getComputedStyle(input).fontSize)}));
  });
 }
 window.OMSNativeLoginInput={refresh,attach(id){if(id!==documentId||attached)return;attached=true;input.readOnly=true;input.style.opacity='0';input.tabIndex=-1;input.setAttribute('aria-hidden','true');},setValue(value,id){if(id!==documentId)return;input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));},next(id){if(id===documentId)document.getElementById('pin')?.focus();}};
 document.getElementById('loginForm').addEventListener('submit',()=>{if(attached&&!input.disabled)input.value=bridge.value();},true);
 input.addEventListener('focus',()=>{if(attached)bridge.focus();});
 new MutationObserver(refresh).observe(document.getElementById('loginShell'),{subtree:true,attributes:true,attributeFilter:['class','style','hidden','disabled']});
 new ResizeObserver(refresh).observe(input);
 addEventListener('resize',refresh);addEventListener('scroll',refresh,true);visualViewport?.addEventListener('resize',refresh);visualViewport?.addEventListener('scroll',refresh);
 addEventListener('pagehide',()=>{cancelAnimationFrame(frame);bridge.hide();});refresh();
})();
