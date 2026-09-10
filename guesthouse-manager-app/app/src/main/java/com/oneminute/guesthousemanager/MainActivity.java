package com.oneminute.guesthousemanager;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FirebaseFirestore;
import com.google.firebase.messaging.FirebaseMessaging;
import java.util.HashMap;
import java.util.Map;

public class MainActivity extends AppCompatActivity {
    private final FirebaseAuth auth = FirebaseAuth.getInstance();
    private final FirebaseFirestore db = FirebaseFirestore.getInstance();
    private LinearLayout root;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (android.os.Build.VERSION.SDK_INT >= 33 && ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.POST_NOTIFICATIONS}, 10);
        showEntry();
    }

    private void base() {
        root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(42,55,42,42); root.setBackgroundColor(Color.rgb(244,247,252));
        setContentView(root);
    }

    private TextView title(String text, int size) {
        TextView v=new TextView(this); v.setText(text); v.setTextSize(size); v.setTextColor(Color.rgb(24,49,83)); v.setPadding(0,12,0,24); v.setTypeface(null,1); return v;
    }

    private EditText input(String hint, boolean password) {
        EditText e=new EditText(this); e.setHint(hint); e.setTextSize(17); e.setPadding(25,18,25,18);
        if(password)e.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(e,new LinearLayout.LayoutParams(-1,-2)); return e;
    }

    private Button button(String text, int color) {
        Button b=new Button(this); b.setText(text); b.setTextSize(18); b.setTextColor(Color.WHITE); b.setBackgroundColor(color);
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,150); p.setMargins(0,18,0,0); root.addView(b,p); return b;
    }

    private void showEntry() { if(auth.getCurrentUser()==null) showLogin(); else loadUser(); }

    private void showLogin() {
        base(); root.addView(title("Guesthouse Manager",32));
        TextView sub=title("원미닛 직원 관리",16); sub.setTextColor(Color.GRAY); root.addView(sub);
        EditText email=input("이메일",false), password=input("비밀번호",true);
        Button login=button("로그인",Color.rgb(36,103,189));
        login.setOnClickListener(v -> { login.setEnabled(false); auth.signInWithEmailAndPassword(email.getText().toString().trim(),password.getText().toString()).addOnCompleteListener(t->{ if(t.isSuccessful())loadUser(); else {login.setEnabled(true);Toast.makeText(this,"로그인 정보를 확인해주세요.",Toast.LENGTH_LONG).show();}}); });
    }

    private void loadUser() {
        String uid=auth.getCurrentUser().getUid();
        db.collection("users").document(uid).get().addOnSuccessListener(doc->{
            String role=doc.getString("role"); String branch=doc.getString("branch");
            registerToken(role,branch); showMenu(role,branch);
        }).addOnFailureListener(e->Toast.makeText(this,"사용자 정보를 읽지 못했습니다.",Toast.LENGTH_LONG).show());
    }

    private void registerToken(String role,String branch) {
        FirebaseMessaging.getInstance().getToken().addOnSuccessListener(token->{ Map<String,Object> d=new HashMap<>(); d.put("token",token); d.put("role",role); d.put("branch",branch==null?"":branch); db.collection("deviceTokens").document(auth.getUid()).set(d); });
    }

    private void showMenu(String role,String branch) {
        base(); root.addView(title("Guesthouse Manager",30));
        TextView who=title("owner".equals(role)?"사장님 계정":"ONE MINUTE · 공용 게하폰",15); who.setTextColor(Color.GRAY); root.addView(who);
        Button attendance=button("출퇴근 보고",Color.rgb(36,103,189));
        attendance.setOnClickListener(v->startActivity(new Intent(this,AttendanceActivity.class)));
        Button emergency=button("사장님께 긴급보고",Color.rgb(211,61,61));
        emergency.setVisibility("owner".equals(role)?View.GONE:View.VISIBLE);
        emergency.setOnClickListener(v->startActivity(new Intent(this,EmergencyReportActivity.class)));
        Button mission=button("미션",Color.rgb(67,87,112)); mission.setOnClickListener(v->Toast.makeText(this,"미션 기능은 다음 버전에 추가됩니다.",Toast.LENGTH_SHORT).show());
        Button logout=button("로그아웃",Color.GRAY); logout.setOnClickListener(v->{auth.signOut();showLogin();});
    }
}
