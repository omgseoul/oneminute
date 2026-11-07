package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.text.*;
import android.util.TypedValue;
import android.view.*;
import android.view.inputmethod.*;
import android.webkit.*;
import android.widget.*;
import org.json.JSONObject;

/** A native username editor in the existing web form; PIN/auth remain unchanged. */
public final class NativeLoginInput {
 private final Activity activity;private final WebView web;private final EditText editor;
 private volatile String value="";private String documentId="";private boolean allowed,initialized,syncing;
 NativeLoginInput(Activity activity,WebView web,FrameLayout root){
  this.activity=activity;this.web=web;editor=new EditText(activity);editor.setId(View.generateViewId());
  editor.setSingleLine(true);editor.setInputType(InputType.TYPE_CLASS_TEXT);editor.setImeOptions(EditorInfo.IME_ACTION_NEXT|EditorInfo.IME_FLAG_NO_EXTRACT_UI);
  editor.setFilters(new InputFilter[]{new InputFilter.LengthFilter(50)});editor.setTextColor(Color.rgb(23,36,58));editor.setHintTextColor(Color.rgb(109,123,144));editor.setHint("아이디를 입력하세요");editor.setContentDescription("아이디");editor.setAutofillHints(View.AUTOFILL_HINT_USERNAME);editor.setSelectAllOnFocus(false);editor.setVisibility(View.GONE);
  root.addView(editor,new FrameLayout.LayoutParams(1,1));web.addJavascriptInterface(this,"OMSLoginInput");
  editor.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){value=s.toString();if(!syncing&&allowed)sendValue();}public void afterTextChanged(Editable s){}});
  editor.setOnEditorActionListener((v,action,event)->{if(action!=EditorInfo.IME_ACTION_NEXT)return false;sendValue();editor.clearFocus();web.requestFocus();web.evaluateJavascript("window.OMSNativeLoginInput?.next("+JSONObject.quote(documentId)+")",null);return true;});
  editor.setOnFocusChangeListener((v,focused)->{border(focused);});
 }
 private boolean trusted(){String url=web.getUrl();if(url==null)return false;Uri u=Uri.parse(url);return "https".equals(u.getScheme())&&("omgworks24.com".equals(u.getHost())||"www.omgworks24.com".equals(u.getHost()))&&"/login.html".equals(u.getPath());}
 void started(){allowed=false;initialized=false;documentId="";value="";editor.clearFocus();editor.setVisibility(View.GONE);syncing=true;editor.setText("");syncing=false;}
 void finished(){allowed=trusted();if(allowed)web.evaluateJavascript("window.OMSNativeLoginInput?.refresh()",null);}
 private void border(boolean focused){GradientDrawable bg=new GradientDrawable();bg.setColor(Color.WHITE);bg.setCornerRadius(dp(13));bg.setStroke(dp(1),focused?Color.rgb(106,157,221):Color.rgb(207,218,234));editor.setBackground(bg);}
 private int dp(int v){return Math.round(v*activity.getResources().getDisplayMetrics().density);}
 private void sendValue(){if(!trusted())return;web.evaluateJavascript("window.OMSNativeLoginInput?.setValue("+JSONObject.quote(value)+","+JSONObject.quote(documentId)+")",null);}
 @JavascriptInterface public String value(){return value;}
 @JavascriptInterface public void hide(){activity.runOnUiThread(()->editor.setVisibility(View.GONE));}
 @JavascriptInterface public void focus(){activity.runOnUiThread(()->{if(allowed&&trusted()&&editor.getVisibility()==View.VISIBLE){editor.requestFocus();((InputMethodManager)activity.getSystemService(Activity.INPUT_METHOD_SERVICE)).showSoftInput(editor,InputMethodManager.SHOW_IMPLICIT);}});}
 @JavascriptInterface public void layout(String json){
  final JSONObject data;try{data=new JSONObject(json);}catch(Exception e){return;}
  activity.runOnUiThread(()->{
   if(!allowed||!trusted())return;String id=data.optString("documentId");if(id.isEmpty())return;
   if(initialized&&!documentId.equals(id))return;
   if(!data.optBoolean("visible")){if(editor.hasFocus()){editor.clearFocus();((InputMethodManager)activity.getSystemService(Activity.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(editor.getWindowToken(),0);}editor.setVisibility(View.GONE);return;}
   double viewport=data.optDouble("viewportWidth",0);if(viewport<=0||web.getWidth()<=0)return;
   float scale=(float)(web.getWidth()/viewport);int width=Math.round((float)data.optDouble("width")*scale),height=Math.round((float)data.optDouble("height")*scale);
   if(width<=0||height<=0||width>web.getWidth()+dp(2)||height>dp(120))return;
   if(!initialized){documentId=id;initialized=true;syncing=true;editor.setText(data.optString("value",""));editor.setSelection(editor.length());syncing=false;}
   FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(width,height);lp.leftMargin=Math.round(web.getX()+(float)data.optDouble("x")*scale);lp.topMargin=Math.round(web.getY()+(float)data.optDouble("y")*scale);editor.setLayoutParams(lp);
   editor.setTextSize(TypedValue.COMPLEX_UNIT_PX,(float)data.optDouble("fontSize",16)*scale);int padding=Math.round(14*scale);editor.setPadding(padding,0,padding,0);editor.setGravity(Gravity.CENTER_VERTICAL);border(editor.hasFocus());editor.setVisibility(View.VISIBLE);
   web.evaluateJavascript("window.OMSNativeLoginInput?.attach("+JSONObject.quote(documentId)+")",null);
  });
 }
 EditText editorForTest(){return editor;}
 void close(){allowed=false;web.removeJavascriptInterface("OMSLoginInput");editor.setVisibility(View.GONE);}
}
