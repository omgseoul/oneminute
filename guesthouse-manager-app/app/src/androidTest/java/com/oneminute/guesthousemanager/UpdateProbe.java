package com.oneminute.guesthousemanager;
import android.app.Instrumentation;
import android.os.Bundle;
public class UpdateProbe extends Instrumentation {
 private String phase;
 @Override public void onCreate(Bundle args) { super.onCreate(args); phase=args.getString("phase", "verify"); start(); }
 @Override public void onStart() {
  if("chat".equals(phase)){NativeStaffChatProbe.run(this);return;}
  Bundle result=new Bundle();
  android.content.SharedPreferences prefs=getTargetContext().getSharedPreferences("oms_update_probe",0);
  if("seed".equals(phase))prefs.edit().putString("marker","continuity-ok").commit();
  boolean ok="continuity-ok".equals(prefs.getString("marker",""));
  result.putString("oms_update",ok?"ok":"failed");finish(ok?-1:0,result);
 }
}
