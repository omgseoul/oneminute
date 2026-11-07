package com.oneminute.guesthousemanager;
import android.inputmethodservice.InputMethodService;
import android.view.View;
import android.view.inputmethod.*;
import android.widget.*;
/** Test-only IME. Uses Android's real current connection, never a test-created connection. */
public class TestHangulIme extends InputMethodService {
 @Override public boolean onEvaluateFullscreenMode(){return false;}
 @Override public View onCreateInputView(){LinearLayout row=new LinearLayout(this);row.setOrientation(LinearLayout.VERTICAL);row.setBackgroundColor(0xffeaf1fa);
  String[] labels={"한글 조합 입력","영문 입력","다음 입력칸"};
  for(int i=0;i<labels.length;i++){final int index=i;Button key=new Button(this);key.setText(labels[i]);key.setOnClickListener(v->{InputConnection c=getCurrentInputConnection();if(c==null)return;if(index==0){for(String part:new String[]{"ㅎ","하","한","한ㄱ","한그","한글"})c.setComposingText(part,1);c.commitText("한글",1);}else if(index==1)c.commitText("abc",1);else c.performEditorAction(EditorInfo.IME_ACTION_NEXT);});row.addView(key,new LinearLayout.LayoutParams(-1,120));}return row;
 }
}
