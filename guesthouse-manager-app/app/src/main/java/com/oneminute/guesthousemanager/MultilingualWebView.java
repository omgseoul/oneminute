package com.oneminute.guesthousemanager;

import android.content.Context;
import android.net.Uri;
import android.os.LocaleList;
import android.text.InputType;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.webkit.WebView;
import java.util.Locale;

/** Login IDs accept Korean composition on the first focus, as well as Latin text. */
public class MultilingualWebView extends WebView {
 public MultilingualWebView(Context context){super(context);setFocusable(true);setFocusableInTouchMode(true);}
 @Override public InputConnection onCreateInputConnection(EditorInfo info){
  InputConnection connection=super.onCreateInputConnection(info);
  String url=getUrl();
  if(url!=null&&"/login.html".equals(Uri.parse(url).getPath()))configureLoginEditor(info);
  return connection;
 }
 static void configureLoginEditor(EditorInfo info){
  int kind=info.inputType&InputType.TYPE_MASK_CLASS,variation=info.inputType&InputType.TYPE_MASK_VARIATION;
  if(kind!=InputType.TYPE_CLASS_TEXT||variation==InputType.TYPE_TEXT_VARIATION_PASSWORD||variation==InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD||variation==InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)return;
  info.imeOptions&=~EditorInfo.IME_FLAG_FORCE_ASCII;
  info.inputType&=~InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
  info.hintLocales=new LocaleList(Locale.KOREAN,Locale.ENGLISH);
 }
}
