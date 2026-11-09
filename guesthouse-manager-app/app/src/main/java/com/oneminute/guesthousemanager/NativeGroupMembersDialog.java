package com.oneminute.guesthousemanager;

import android.app.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.view.*;
import android.widget.*;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import org.json.*;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

/** Same rounded, blue OMS card as worker profiles, with a scrollable member list. */
final class NativeGroupMembersDialog extends Dialog {
    private final Activity activity;
    NativeGroupMembersDialog(Activity activity,JSONObject profile,NativeStaffChatMedia media){
        super(activity);this.activity=activity;requestWindowFeature(Window.FEATURE_NO_TITLE);setTitle("대화 참여자");
        LinearLayout card=column(activity);card.setTag("group-members-card");card.setPadding(dp(activity,21),dp(activity,21),dp(activity,21),dp(activity,21));card.setBackground(background(Color.WHITE,22,activity));
        LinearLayout head=row(activity);TextView heading=text(activity,"대화 참여자",18,INK);heading.setTypeface(null,Typeface.BOLD);head.addView(heading,weighted());ImageButton close=icon(activity,"close","대화 참여자 닫기");close.setTag("group-members-close");head.addView(close,new LinearLayout.LayoutParams(dp(activity,40),dp(activity,40)));close.setOnClickListener(v->dismiss());card.addView(head);
        LinearLayout summary=row(activity);LinearLayout.LayoutParams summarySpace=new LinearLayout.LayoutParams(-1,-2);summarySpace.setMargins(0,dp(activity,20),0,dp(activity,17));card.addView(summary,summarySpace);
        ImageView group=new ImageView(activity);group.setImageResource(R.drawable.ic_staff_group);group.setContentDescription("단체 채팅방");summary.addView(group,new LinearLayout.LayoutParams(dp(activity,54),dp(activity,54)));
        LinearLayout copy=column(activity);copy.setPadding(dp(activity,13),0,0,0);TextView title=text(activity,"단체 채팅방",16,INK);title.setTypeface(null,Typeface.BOLD);copy.addView(title);TextView count=text(activity,profile.optInt("member_count")+"명 참여 중",12,MUTED);count.setPadding(0,dp(activity,5),0,0);copy.addView(count);summary.addView(copy,weighted());
        LinearLayout people=column(activity);people.setTag("group-members-list");people.setPadding(dp(activity,14),0,dp(activity,14),0);people.setBackground(background(0xfff5f7fa,14,activity));JSONArray members=profile.optJSONArray("members");
        if(members!=null)for(int i=0;i<members.length();i++){
            JSONObject person=members.optJSONObject(i);if(person==null)continue;String name=person.optString("display_name","근무자");
            LinearLayout row=row(activity);row.setPadding(0,dp(activity,12),0,dp(activity,12));row.setMinimumHeight(dp(activity,64));
            FrameLayout face=new FrameLayout(activity);face.setBackground(background(SOFT,20,activity));face.setClipToOutline(true);TextView initial=text(activity,name.isEmpty()?"?":name.substring(0,name.offsetByCodePoints(0,1)),17,BLUE);initial.setGravity(Gravity.CENTER);face.addView(initial,new FrameLayout.LayoutParams(-1,-1));ImageView photo=new ImageView(activity);photo.setScaleType(ImageView.ScaleType.CENTER_CROP);photo.setContentDescription(name+" 프로필 사진");face.addView(photo,new FrameLayout.LayoutParams(-1,-1));media.avatar(photo,person.optString("profile_image"));face.setTag("group-member-avatar-"+i);row.addView(face,new LinearLayout.LayoutParams(dp(activity,40),dp(activity,40)));
            LinearLayout labels=column(activity);labels.setPadding(dp(activity,12),0,0,0);TextView memberName=text(activity,name,14,INK);memberName.setTypeface(null,Typeface.BOLD);memberName.setTag("group-member-name-"+i);labels.addView(memberName);TextView branch=text(activity,person.optString("property_name"),12,MUTED);branch.setPadding(0,dp(activity,4),0,0);labels.addView(branch);row.addView(labels,weighted());people.addView(row);
            if(i<members.length()-1){View divider=new View(activity);divider.setBackgroundColor(0xffe5ebf2);people.addView(divider,new LinearLayout.LayoutParams(-1,dp(activity,1)));}
        }
        ScrollView scroll=new ScrollView(activity){@Override protected void onMeasure(int widthSpec,int heightSpec){
            int available=activity.getResources().getDisplayMetrics().heightPixels-dp(activity,210);WindowInsetsCompat insets=ViewCompat.getRootWindowInsets(activity.getWindow().getDecorView());if(insets!=null){androidx.core.graphics.Insets safe=insets.getInsets(WindowInsetsCompat.Type.systemBars()|WindowInsetsCompat.Type.displayCutout()|WindowInsetsCompat.Type.ime());available-=safe.top+safe.bottom;}if(MeasureSpec.getMode(heightSpec)!=MeasureSpec.UNSPECIFIED)available=Math.min(available,MeasureSpec.getSize(heightSpec));super.onMeasure(widthSpec,MeasureSpec.makeMeasureSpec(Math.max(dp(activity,60),available),MeasureSpec.AT_MOST));
        }};scroll.setTag("group-members-scroll");scroll.setClipToOutline(true);scroll.setBackground(background(0xfff5f7fa,14,activity));scroll.addView(people);card.addView(scroll);setContentView(card);setCanceledOnTouchOutside(true);
        Window window=getWindow();if(window!=null){window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);window.setDimAmount(.38f);window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN|WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);}
    }
    @Override public void show(){super.show();Window window=getWindow();if(window!=null){window.setGravity(Gravity.CENTER);window.setLayout(Math.min(dp(activity,360),Math.max(1,activity.getResources().getDisplayMetrics().widthPixels-dp(activity,36))),WindowManager.LayoutParams.WRAP_CONTENT);}}
}
