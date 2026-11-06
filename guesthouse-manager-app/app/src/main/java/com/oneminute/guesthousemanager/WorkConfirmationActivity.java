package com.oneminute.guesthousemanager;

import android.app.NotificationManager;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.view.*;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import org.json.JSONObject;
import java.time.Instant;
import java.util.concurrent.*;

/** Attendance continuation requires an explicit, server-accepted answer. */
public class WorkConfirmationActivity extends AppCompatActivity {
 static final int NOTIFICATION_ID=9130;
 interface Api {JSONObject request(String confirmationId)throws Exception;}
 static Api testingApi;
 private final Handler main=new Handler(Looper.getMainLooper());
 private final ExecutorService worker=Executors.newSingleThreadExecutor();
 private TextView remaining,error;private Button yes;private String confirmationId;
 private long deadlineElapsed;private boolean busy,destroyed;
 private final Runnable poll=new Runnable(){public void run(){request(null);main.postDelayed(this,10000);}};
 private final Runnable tick=new Runnable(){public void run(){updateCountdown();main.postDelayed(this,1000);}};
 @Override protected void onCreate(Bundle state){super.onCreate(state);if(Build.VERSION.SDK_INT>=27){setShowWhenLocked(true);setTurnScreenOn(true);}getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);build();}
 @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);request(null);}
 @Override protected void onResume(){super.onResume();main.removeCallbacks(poll);main.removeCallbacks(tick);main.post(poll);main.post(tick);}
 @Override protected void onPause(){super.onPause();main.removeCallbacks(poll);main.removeCallbacks(tick);}
 @Override protected void onDestroy(){destroyed=true;main.removeCallbacksAndMessages(null);worker.shutdownNow();super.onDestroy();}
 @Override public void onBackPressed(){/* A dismiss action must never mean continued work. */}
 private void build(){
  FrameLayout shade=new FrameLayout(this);shade.setBackgroundColor(Color.argb(125,18,39,66));shade.setPadding(dp(20),dp(32),dp(20),dp(32));
  ViewCompat.setOnApplyWindowInsetsListener(shade,(v,insets)->{androidx.core.graphics.Insets bars=insets.getInsets(WindowInsetsCompat.Type.systemBars());v.setPadding(dp(20)+bars.left,dp(24)+bars.top,dp(20)+bars.right,dp(24)+bars.bottom);return insets;});
  ScrollView scroll=new ScrollView(this);scroll.setBackground(round(Color.WHITE,26));
  LinearLayout card=new LinearLayout(this);card.setOrientation(LinearLayout.VERTICAL);card.setPadding(dp(24),dp(26),dp(24),dp(23));scroll.addView(card);
  TextView title=label("근무 12시간 초과 알림",24,Color.rgb(24,49,83));title.setTypeface(Typeface.DEFAULT,Typeface.BOLD);card.addView(title);
  TextView body=label("근무중인 경우 아래의 버튼을 눌러주십시오.\n10분 안에 누르지 않으면 퇴근 처리되며, 이후 별도로 수정하여 주십시오.",16,Color.rgb(104,121,139));add(card,body,16);
  remaining=label("근무 상태를 확인하고 있습니다…",13,Color.rgb(36,103,189));add(card,remaining,15);
  error=label("",13,Color.rgb(194,59,72));add(card,error,8);
  yes=new Button(this);yes.setText("예, 계속 근무중입니다.");yes.setAllCaps(false);yes.setTextSize(16);yes.setTypeface(Typeface.DEFAULT,Typeface.BOLD);yes.setTextColor(Color.WHITE);yes.setBackground(round(Color.rgb(36,103,189),14));yes.setMinHeight(dp(52));yes.setEnabled(false);yes.setOnClickListener(v->request(confirmationId));add(card,yes,14);
  shade.addView(scroll,new FrameLayout.LayoutParams(-1,-2,Gravity.CENTER));setContentView(shade);
 }
 private void request(String id){
  if(busy||destroyed)return;busy=true;yes.setEnabled(false);
  worker.execute(()->{
   try{
    Api api=BuildConfig.DEBUG&&testingApi!=null?testingApi:(confirmation)->new NativeStaffChatApi(this,true).rpc("work_shift_confirmation",new JSONObject().put("p_confirmation_id",confirmation==null?JSONObject.NULL:confirmation));
    JSONObject data=api.request(id);
    main.post(()->{if(destroyed)return;busy=false;error.setText("");JSONObject pending=data.optJSONObject("pending");
     if(pending==null){getSystemService(NotificationManager.class).cancel(NOTIFICATION_ID);NativeMessageBadge.changed(this);finish();return;}
     confirmationId=pending.optString("id");
     try{long left=Instant.parse(pending.getString("deadline_at")).toEpochMilli()-Instant.parse(data.getString("server_now")).toEpochMilli();deadlineElapsed=SystemClock.elapsedRealtime()+Math.max(0,left);}catch(Exception e){deadlineElapsed=0;}
     updateCountdown();
    });
   }catch(Exception e){main.post(()->{if(destroyed)return;busy=false;error.setText("연결을 확인하고 다시 눌러주세요. 서버 확인 후 근무가 연장됩니다.");updateCountdown();});}
  });
 }
 private void updateCountdown(){if(remaining==null||confirmationId==null)return;long seconds=Math.max(0,(deadlineElapsed-SystemClock.elapsedRealtime()+999)/1000);remaining.setText(seconds>0?"확인까지 "+(seconds/60)+"분 "+String.format(java.util.Locale.KOREA,"%02d",seconds%60)+"초 남음":"확인 시간이 지나 근무 종료 상태를 확인하고 있습니다.");yes.setEnabled(!busy&&seconds>0);}
 private TextView label(String text,int size,int color){TextView v=new TextView(this);v.setText(text);v.setTextSize(size);v.setTextColor(color);v.setLineSpacing(dp(3),1.15f);return v;}
 private void add(LinearLayout parent,View view,int margin){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.topMargin=dp(margin);parent.addView(view,p);}
 private GradientDrawable round(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
 private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
}
