package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.view.*;
import android.widget.*;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import org.json.JSONObject;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

/** Native counterpart of the shared message-profiles.css worker information card. */
final class NativeStaffProfileDialog extends Dialog {
    private static final int PROFILE_INK=0xff183153;
    private final Activity activity;
    private final NativeStaffChatMedia media;
    private final java.util.Map<String,TextView> details=new java.util.HashMap<>();
    private TextView personName,personInitial,status,retry;
    private ImageView personPhoto;

    NativeStaffProfileDialog(Activity activity,JSONObject profile,NativeStaffChatMedia media){
        super(activity);this.activity=activity;this.media=media;
        requestWindowFeature(Window.FEATURE_NO_TITLE);setTitle("근무자 정보");
        LinearLayout card=column(activity);card.setTag("staff-profile-card");card.setPadding(dp(activity,21),dp(activity,21),dp(activity,21),dp(activity,21));card.setBackground(background(Color.WHITE,22,activity));
        LinearLayout top=row(activity);
        TextView heading=text(activity,"근무자 정보",18,PROFILE_INK);heading.setTag("staff-profile-title");heading.setTypeface(null,Typeface.BOLD);top.addView(heading,weighted());
        ImageButton close=new ImageButton(activity);close.setTag("staff-profile-close");close.setContentDescription("근무자 정보 닫기");
        android.graphics.drawable.Drawable cross=new android.graphics.drawable.Drawable(){
            final android.graphics.Paint paint=new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
            @Override public void draw(android.graphics.Canvas canvas){android.graphics.Rect b=getBounds();paint.setColor(PROFILE_INK);paint.setStrokeWidth(Math.max(2,b.width()*.075f));paint.setStrokeCap(android.graphics.Paint.Cap.ROUND);float inset=b.width()*.1f;canvas.drawLine(b.left+inset,b.top+inset,b.right-inset,b.bottom-inset,paint);canvas.drawLine(b.right-inset,b.top+inset,b.left+inset,b.bottom-inset,paint);}
            @Override public void setAlpha(int a){paint.setAlpha(a);}@Override public void setColorFilter(android.graphics.ColorFilter f){paint.setColorFilter(f);}@Override public int getOpacity(){return android.graphics.PixelFormat.TRANSLUCENT;}
        };
        close.setImageDrawable(cross);close.setBackground(new android.graphics.drawable.InsetDrawable(background(0xfff2f5f9,17,activity),dp(activity,5)));close.setPadding(dp(activity,11),dp(activity,11),dp(activity,11),dp(activity,11));top.addView(close,new LinearLayout.LayoutParams(dp(activity,44),dp(activity,44)));close.setOnClickListener(v->dismiss());card.addView(top);
        String name=value(profile,"display_name");if("-".equals(name))name="근무자";
        LinearLayout person=row(activity);LinearLayout.LayoutParams personSpace=new LinearLayout.LayoutParams(-1,-2);personSpace.setMargins(0,dp(activity,20),0,dp(activity,17));card.addView(person,personSpace);
        FrameLayout avatar=new FrameLayout(activity);avatar.setTag("staff-profile-avatar");avatar.setBackground(background(PROFILE_INK,27,activity));avatar.setClipToOutline(true);
        TextView initial=text(activity,name.substring(0,name.offsetByCodePoints(0,1)),22,Color.WHITE);initial.setGravity(Gravity.CENTER);avatar.addView(initial,new FrameLayout.LayoutParams(-1,-1));
        personInitial=initial;
        ImageView photo=new ImageView(activity);photo.setTag("staff-profile-photo");photo.setScaleType(ImageView.ScaleType.CENTER_CROP);photo.setContentDescription(name+" 프로필 사진");avatar.addView(photo,new FrameLayout.LayoutParams(-1,-1));media.avatar(photo,profile.optString("profile_image"));person.addView(avatar,new LinearLayout.LayoutParams(dp(activity,54),dp(activity,54)));
        TextView displayName=text(activity,name,16,PROFILE_INK);displayName.setTag("staff-profile-name");displayName.setTypeface(null,Typeface.BOLD);LinearLayout.LayoutParams nameSpace=weighted();nameSpace.leftMargin=dp(activity,13);person.addView(displayName,nameSpace);
        personName=displayName;personPhoto=photo;
        LinearLayout fields=column(activity);fields.setTag("staff-profile-fields");fields.setPadding(dp(activity,14),0,dp(activity,14),0);fields.setBackground(background(0xfff5f7fa,14,activity));card.addView(fields);
        String[][] definitions={{"이름","display_name"},{"직무","job_title"},{"지점","property_name"},{"연락처","contact_phone"}};
        for(int i=0;i<definitions.length;i++){
            LinearLayout line=row(activity);line.setGravity(Gravity.TOP);line.setPadding(0,dp(activity,12),0,dp(activity,12));
            TextView label=text(activity,definitions[i][0],12,0xff65748a);label.setGravity(Gravity.TOP);LinearLayout.LayoutParams labelSpace=new LinearLayout.LayoutParams(dp(activity,58),-2);labelSpace.rightMargin=dp(activity,10);line.addView(label,labelSpace);
            TextView detail=text(activity,value(profile,definitions[i][1]),13,PROFILE_INK);detail.setTag("staff-profile-"+definitions[i][1]);detail.setGravity(Gravity.TOP);detail.setTextIsSelectable(true);line.addView(detail,weighted());fields.addView(line);
            details.put(definitions[i][1],detail);
            if(i<definitions.length-1){View divider=new View(activity);divider.setBackgroundColor(0xffe5ebf2);fields.addView(divider,new LinearLayout.LayoutParams(-1,dp(activity,1)));}
        }
        status=text(activity,"",12,0xff65748a);status.setTag("staff-profile-status");status.setPadding(0,dp(activity,13),0,0);status.setVisibility(View.GONE);card.addView(status);
        retry=button(activity,"다시 불러오기","근무자 정보 다시 불러오기");retry.setTag("staff-profile-retry");retry.setVisibility(View.GONE);LinearLayout.LayoutParams retrySpace=new LinearLayout.LayoutParams(-2,-2);retrySpace.topMargin=dp(activity,10);card.addView(retry,retrySpace);
        ScrollView scroll=new ScrollView(activity){@Override protected void onMeasure(int widthSpec,int heightSpec){
            int limit=activity.getResources().getDisplayMetrics().heightPixels-dp(activity,48);
            WindowInsetsCompat insets=ViewCompat.getRootWindowInsets(activity.getWindow().getDecorView());
            if(insets!=null){androidx.core.graphics.Insets safe=insets.getInsets(WindowInsetsCompat.Type.systemBars()|WindowInsetsCompat.Type.displayCutout());limit-=safe.top+safe.bottom;}
            if(MeasureSpec.getMode(heightSpec)!=MeasureSpec.UNSPECIFIED)limit=Math.min(limit,MeasureSpec.getSize(heightSpec));
            super.onMeasure(widthSpec,MeasureSpec.makeMeasureSpec(Math.max(1,limit),MeasureSpec.AT_MOST));
        }};
        scroll.setTag("staff-profile-scroll");scroll.setClipToOutline(true);scroll.setBackground(background(Color.WHITE,22,activity));scroll.addView(card);setContentView(scroll);setCanceledOnTouchOutside(true);
        Window window=getWindow();if(window!=null){window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);window.setDimAmount(.38f);window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);}
    }
    void bind(JSONObject profile){
        String name=value(profile,"display_name");if("-".equals(name))name="근무자";
        personName.setText(name);personInitial.setText(name.substring(0,name.offsetByCodePoints(0,1)));personPhoto.setContentDescription(name+" 프로필 사진");media.avatar(personPhoto,profile.optString("profile_image"));
        for(java.util.Map.Entry<String,TextView> entry:details.entrySet())entry.getValue().setText(value(profile,entry.getKey()));
        status.setVisibility(View.GONE);retry.setVisibility(View.GONE);
    }
    void loading(){status.setText("정보를 불러오는 중입니다.");status.setVisibility(View.VISIBLE);retry.setVisibility(View.GONE);}
    void failed(String message,Runnable reload){status.setText(message);status.setVisibility(View.VISIBLE);retry.setVisibility(View.VISIBLE);retry.setOnClickListener(v->reload.run());}
    static String value(JSONObject profile,String key){return profile.isNull(key)||profile.optString(key).trim().isEmpty()?"-":profile.optString(key).trim();}
    @Override public void show(){super.show();Window window=getWindow();if(window!=null){window.setGravity(Gravity.CENTER);window.setLayout(Math.min(dp(activity,360),Math.max(1,activity.getResources().getDisplayMetrics().widthPixels-dp(activity,36))),WindowManager.LayoutParams.WRAP_CONTENT);}}
}
