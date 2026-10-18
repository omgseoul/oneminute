(() => {
  const input=document.getElementById('body'),toggle=document.getElementById('emojiToggle'),panel=document.getElementById('emojiPanel');
  if(!input||!toggle||!panel)return;
  const emojis=['😀','😄','😊','🙂','😉','😍','🥰','😘','😎','🤔','😅','😂','🤣','🥲','😭','😢','😮','😴','😡','🙏','👍','👎','👏','🙌','👌','✌️','👋','💪','❤️','🧡','💛','💚','💙','💜','💕','💯','✅','❌','❗','❓','🎉','🎂','🎁','⭐','✨','🔥','☀️','☕','🍀','🌸','🏠','🛏️','🧹','🧼'];
  let start=0,end=0;
  const remember=()=>{start=input.selectionStart??input.value.length;end=input.selectionEnd??start;};
  ['select','keyup','click','input','blur'].forEach(event=>input.addEventListener(event,remember));
  const close=()=>{panel.hidden=true;toggle.setAttribute('aria-expanded','false');};
  emojis.forEach(emoji=>{const button=document.createElement('button');button.type='button';button.textContent=emoji;button.setAttribute('aria-label',emoji+' 삽입');button.onclick=()=>{
    if(input.disabled)return;
    const limit=input.maxLength>0?input.maxLength:2000;
    if(input.value.length-(end-start)+emoji.length>limit)return;
    input.setRangeText(emoji,start,end,'end');remember();input.dispatchEvent(new Event('input',{bubbles:true}));input.focus();
  };panel.append(button);});
  toggle.onpointerdown=event=>{remember();event.preventDefault();};
  toggle.onclick=()=>{if(input.disabled)return;panel.hidden=!panel.hidden;toggle.setAttribute('aria-expanded',String(!panel.hidden));};
  document.addEventListener('click',event=>{if(!panel.hidden&&!panel.contains(event.target)&&!toggle.contains(event.target))close();});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!panel.hidden){event.preventDefault();event.stopPropagation();close();toggle.focus();}},true);
})();
