package com.oneminute.guesthousemanager;

import android.app.AlertDialog;
import android.os.Bundle;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import com.google.firebase.Timestamp;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.*;
import java.text.SimpleDateFormat;
import java.util.*;

public class OwnerInboxActivity extends AppCompatActivity {
    private final FirebaseFirestore db=FirebaseFirestore.getInstance();
    private LinearLayout list;
    private ListenerRegistration listener;
    private String openedAlertId;
    @Override protected void onCreate(Bundle state){
        super.onCreate(state);
        openedAlertId=getIntent().getStringExtra("alertId");
        String uid=FirebaseAuth.getInstance().getUid();
        if(uid==null){finish();return;}
        db.collection("users").document(uid).get().addOnSuccessListener(user->{
            if(!"owner".equals(user.getString("role"))){finish();return;}
            String branch=user.getString("branch");
            if(branch==null||branch.isEmpty()){finish();return;}
            buildScreen();
            listener=db.collection("alerts").whereEqualTo("branch",branch).addSnapshotListener((snapshot,error)->{
                if(error!=null){Toast.makeText(this,"메시지를 불러오지 못했습니다.",Toast.LENGTH_LONG).show();return;}
                list.removeAllViews();
                List<DocumentSnapshot> messages=new ArrayList<>();
                if(snapshot!=null)for(DocumentSnapshot doc:snapshot)if("owner".equals(doc.getString("targetRole")))messages.add(doc);
                messages.sort((a,b)->Long.compare(time(b.getTimestamp("createdAt")),time(a.getTimestamp("createdAt"))));
                if(messages.isEmpty()){TextView empty=label("받은 긴급보고가 없습니다.",16);empty.setTextColor(Color.GRAY);list.addView(empty);return;}
                for(DocumentSnapshot doc:messages)addMessage(doc);
                if(openedAlertId!=null)for(DocumentSnapshot doc:messages)if(openedAlertId.equals(doc.getId())){openedAlertId=null;showMessage(doc);break;}
            });
        }).addOnFailureListener(e->finish());
    }
    private void buildScreen(){
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),0);root.setBackgroundColor(Color.rgb(240,247,253));
        TextView heading=label("‹   온 메시지 확인함",24);heading.setOnClickListener(v->finish());root.addView(heading);
        ScrollView scroll=new ScrollView(this);list=new LinearLayout(this);list.setOrientation(LinearLayout.VERTICAL);list.setPadding(0,dp(12),0,dp(70));scroll.addView(list);root.addView(scroll);setContentView(root);
    }
    private void addMessage(DocumentSnapshot doc){
        LinearLayout card=new LinearLayout(this);card.setOrientation(LinearLayout.VERTICAL);card.setPadding(dp(16),dp(14),dp(16),dp(14));
        GradientDrawable bg=new GradientDrawable();bg.setColor(Color.WHITE);bg.setCornerRadius(dp(18));bg.setStroke(dp(1),Color.rgb(220,230,240));card.setBackground(bg);
        TextView title=label("🚨  직원 긴급보고",17);title.setTextColor(Color.rgb(190,48,56));card.addView(title);
        TextView body=label(value(doc.getString("message")),16);body.setMaxLines(3);body.setEllipsize(android.text.TextUtils.TruncateAt.END);card.addView(body);
        Timestamp at=doc.getTimestamp("createdAt");TextView time=label(at==null?"방금":new SimpleDateFormat("yyyy.MM.dd HH:mm",Locale.KOREA).format(at.toDate()),12);time.setTextColor(Color.GRAY);card.addView(time);
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.bottomMargin=dp(10);list.addView(card,p);card.setOnClickListener(v->showMessage(doc));
    }
    private void showMessage(DocumentSnapshot doc){new AlertDialog.Builder(this).setTitle("직원 긴급보고").setMessage(value(doc.getString("message"))).setPositiveButton("확인",null).show();}
    private TextView label(String s,int size){TextView t=new TextView(this);t.setText(s);t.setTextSize(size);t.setTextColor(Color.rgb(24,49,83));t.setPadding(0,dp(6),0,dp(6));return t;}
    private String value(String s){return s==null?"":s;}
    private long time(Timestamp t){return t==null?0:t.toDate().getTime();}
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    @Override protected void onDestroy(){if(listener!=null)listener.remove();super.onDestroy();}
}
