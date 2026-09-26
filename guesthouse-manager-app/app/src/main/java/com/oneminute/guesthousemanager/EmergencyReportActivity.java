package com.oneminute.guesthousemanager;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import androidx.appcompat.app.AppCompatActivity;
/** Compatibility entry point: all business data and authorization live in Supabase. */
public class EmergencyReportActivity extends AppCompatActivity {
 @Override protected void onCreate(Bundle state) {
  super.onCreate(state);
  String url = "https://omgworks24.com/emergency.html";
  String id = getIntent().getStringExtra("alertId");
  if (id != null && id.matches("[0-9a-fA-F-]{36}")) url += "?message_id=" + Uri.encode(id);
  startActivity(new Intent(this, AttendanceActivity.class).setData(Uri.parse(url))
    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP));
  finish();
 }
}
