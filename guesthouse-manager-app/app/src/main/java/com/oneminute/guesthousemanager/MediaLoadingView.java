package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.*;
import android.view.*;
import android.widget.*;
import java.util.Locale;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

/** Determinate bytes received; preparation has its own indeterminate state. */
final class MediaLoadingView extends LinearLayout {
    private final Ring ring;
    private final TextView label,detail,action;
    MediaLoadingView(Context c,Runnable cancel){
        super(c);setOrientation(VERTICAL);setGravity(Gravity.CENTER);setTag("media-loading");
        ring=new Ring(c);addView(ring,new LinearLayout.LayoutParams(dp(c,104),dp(c,104)));
        label=text(c,"파일 정보를 확인하는 중…",14,Color.WHITE);label.setGravity(Gravity.CENTER);label.setPadding(0,dp(c,18),0,0);addView(label);
        detail=text(c,"",12,0xffb6bbc3);detail.setGravity(Gravity.CENTER);detail.setPadding(0,dp(c,6),0,0);addView(detail);
        action=text(c,"취소",14,0xffd1d4da);action.setGravity(Gravity.CENTER);action.setMinWidth(dp(c,80));action.setMinHeight(dp(c,44));action.setOnClickListener(v->cancel.run());addView(action);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
    }
    void progress(long received,long total,boolean video){
        int value=total>0?(int)Math.min(100,received*100/total):-1;
        ring.value=value;ring.invalidate();label.setText(video?"동영상 불러오는 중":"사진 불러오는 중");
        detail.setText(total>0?String.format(Locale.KOREA,"%.1f / %.1f MB",received/1048576d,total/1048576d):"파일 정보를 확인하는 중…");
        setContentDescription(label.getText()+" "+(value>=0?value+"%":""));
    }
    void preparing(boolean video){ring.value=-1;ring.invalidate();label.setText(video?"재생 준비 중…":"사진 준비 중…");detail.setText("");setContentDescription(label.getText());}
    void failed(String message,Runnable retry){ring.setVisibility(GONE);label.setText(message);detail.setText("");action.setText("다시 시도");action.setOnClickListener(v->retry.run());setContentDescription(message);}
    private static final class Ring extends View {
        int value=-1;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        Ring(Context c){super(c);}
        @Override protected void onDraw(Canvas canvas){
            float stroke=dp(getContext(),4),pad=stroke*2;RectF bounds=new RectF(pad,pad,getWidth()-pad,getHeight()-pad);
            paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(stroke);paint.setStrokeCap(Paint.Cap.ROUND);paint.setColor(0xff34373c);canvas.drawOval(bounds,paint);paint.setColor(0xff4c93ff);
            canvas.drawArc(bounds,value<0?(android.os.SystemClock.uptimeMillis()%1400)*360f/1400-90:-90,value<0?85:value*3.6f,false,paint);
            if(value>=0){paint.setStyle(Paint.Style.FILL);paint.setColor(Color.WHITE);paint.setTextSize(dp(getContext(),25));paint.setTextAlign(Paint.Align.CENTER);canvas.drawText(value+"%",getWidth()/2f,getHeight()/2f-(paint.ascent()+paint.descent())/2,paint);}
            else if(isShown())postInvalidateDelayed(32);
        }
    }
}
