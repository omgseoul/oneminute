(function(){
 let sequence=0;
 function mount(select,{title='선택',placeholder='선택'}={}){
  if(!select||select.dataset.pickerMounted)return null;
  if(!select.id)select.id='nativeSelect'+(++sequence);
  select.dataset.pickerMounted='1';select.classList.add('native-picker-source');
  const host=document.createElement('div');host.className='native-picker-host';host.id=select.id+'PickerHost';select.after(host);
  const options=()=>[...select.options].map(option=>({value:option.value,label:option.textContent}));
  const picker=window.omgPropertySelector.mountSingle({host,items:options(),value:select.value,title,placeholder,onChange(value){select.value=value;select.dispatchEvent(new Event('change',{bubbles:true}));}});
  const button=host.querySelector('button');button.id=select.id+'PickerButton';button.setAttribute('aria-label',title);
  const label=select.labels?.[0];if(label)label.htmlFor=button.id;
  const refresh=()=>{picker.setItems(options(),select.value);host.querySelector('button').id=button.id;host.querySelector('button').setAttribute('aria-label',title);};
  const observer=new MutationObserver(refresh);observer.observe(select,{childList:true,subtree:true,characterData:true});
  select.addEventListener('change',refresh);
  return {refresh,picker,destroy(){observer.disconnect();select.removeEventListener('change',refresh);picker.destroy?.();}};
 }
 const style=document.createElement('style');style.textContent='.native-picker-source{display:none!important}.native-picker-host{width:100%;min-width:0}.native-picker-host .property-picker{margin:0;width:100%}.native-picker-host .property-picker-button{width:100%;max-width:none;height:52px;justify-content:space-between;padding:0 14px;border-radius:13px;font-size:16px;font-weight:600;text-align:left}.native-picker-host .property-picker-panel{left:0;right:auto;width:100%;max-width:none;z-index:30}';document.head.append(style);
 window.omgSelectPicker={mount};
})();
