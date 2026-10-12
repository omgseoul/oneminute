package com.oneminute.guesthousemanager;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.widget.Toast;
import androidx.appcompat.app.AlertDialog;
import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
public final class AppUpdateChecker {
 private static boolean checking;
 public static synchronized void check(Activity activity,boolean manual) {
  if(checking)return;
  long last=activity.getSharedPreferences("oms_updates",0).getLong("last_check",0);
  if(!manual&&System.currentTimeMillis()-last<24*60*60*1000L)return;
  checking=true;
  new Thread(()->{
   try{
    HttpURLConnection conn=(HttpURLConnection)new URL("https://omgworks24.com/downloads/oms-update.json?t="+System.currentTimeMillis()).openConnection();
    conn.setConnectTimeout(12000);conn.setReadTimeout(12000);conn.setRequestProperty("Cache-Control","no-cache");
    JSONObject info;try(java.io.InputStream in=conn.getInputStream()){java.io.ByteArrayOutputStream buffer=new java.io.ByteArrayOutputStream();byte[] part=new byte[4096];int count;while((count=in.read(part))!=-1){if(buffer.size()+count>32000)throw new IllegalArgumentException();buffer.write(part,0,count);}info=new JSONObject(new String(buffer.toByteArray(),StandardCharsets.UTF_8));}finally{conn.disconnect();}
    PackageInfo current=activity.getPackageManager().getPackageInfo(activity.getPackageName(),Build.VERSION.SDK_INT>=28?PackageManager.GET_SIGNING_CERTIFICATES:PackageManager.GET_SIGNATURES);
    long version=Build.VERSION.SDK_INT>=28?current.getLongVersionCode():current.versionCode;
    long next=info.getLong("version_code");Uri apk=Uri.parse(info.getString("apk_url"));
    if(!"https".equals(apk.getScheme())||!"omgworks24.com".equals(apk.getHost())||apk.getPath()==null||!apk.getPath().startsWith("/downloads/")||!apk.getPath().endsWith(".apk"))throw new IllegalArgumentException();
    {byte[] cert=(Build.VERSION.SDK_INT>=28?current.signingInfo.getApkContentsSigners()[0]:current.signatures[0]).toByteArray();byte[] hash=MessageDigest.getInstance("SHA-256").digest(cert);StringBuilder hex=new StringBuilder();for(byte b:hash)hex.append(String.format("%02x",b&255));if(!hex.toString().equals(info.getString("certificate_sha256")))throw new IllegalStateException("signature");}
    activity.getSharedPreferences("oms_updates",0).edit().putLong("last_check",System.currentTimeMillis()).apply();
    activity.runOnUiThread(()->{if(activity.isFinishing()||activity.isDestroyed())return;if(next<=version){if(manual)Toast.makeText(activity,"최신 버전입니다.",Toast.LENGTH_SHORT).show();return;}new AlertDialog.Builder(activity).setTitle("OMS 업데이트").setMessage("새 버전 "+info.optString("version_name")+"을 설치할 수 있습니다. 기존 앱을 삭제하지 않고 업데이트하세요.").setNegativeButton("나중에",null).setPositiveButton("다운로드",(dialog,which)->activity.startActivity(new Intent(Intent.ACTION_VIEW,apk.buildUpon().appendQueryParameter("v",String.valueOf(next)).build()))).show();});
   }catch(Exception error){if(manual)activity.runOnUiThread(()->Toast.makeText(activity,"업데이트 정보를 확인하지 못했습니다. 잠시 후 다시 시도해주세요.",Toast.LENGTH_LONG).show());}
   finally{synchronized(AppUpdateChecker.class){checking=false;}}
  },"oms-update-check").start();
 }
 private AppUpdateChecker(){}
}
