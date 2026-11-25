package com.omgworks.calendar;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.widget.Toast;
import androidx.core.content.FileProvider;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Downloads a verified replacement APK; Android owns the final install confirmation. */
public final class AppUpdateInstaller {
 private static boolean busy;
 private static int flags(){return Build.VERSION.SDK_INT>=28?PackageManager.GET_SIGNING_CERTIFICATES:PackageManager.GET_SIGNATURES;}
 private static String hex(byte[] data)throws Exception{StringBuilder out=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(data))out.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return out.toString();}
 private static String certificate(PackageInfo p)throws Exception{return hex((Build.VERSION.SDK_INT>=28?p.signingInfo.getApkContentsSigners()[0]:p.signatures[0]).toByteArray());}
 private static long version(PackageInfo p){return Build.VERSION.SDK_INT>=28?p.getLongVersionCode():p.versionCode;}
 private static byte[] fetch(String url,int max)throws Exception{
  Uri u=Uri.parse(url);if(!"https".equals(u.getScheme())||!"omgworks24.com".equals(u.getHost())||(u.getPort()!=-1&&u.getPort()!=443)||u.getPath()==null||!u.getPath().startsWith("/downloads/"))throw new IOException("올바른 업데이트 주소가 아닙니다.");
  HttpURLConnection c=(HttpURLConnection)new URL(url).openConnection();c.setInstanceFollowRedirects(false);c.setConnectTimeout(15000);c.setReadTimeout(30000);c.setRequestProperty("Cache-Control","no-cache");
  try{if(c.getResponseCode()!=200)throw new IOException("업데이트 파일을 내려받지 못했습니다.");try(InputStream in=c.getInputStream();ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] buffer=new byte[16384];int n;while((n=in.read(buffer))!=-1){if(out.size()+n>max)throw new IOException("업데이트 파일 크기를 확인해주세요.");out.write(buffer,0,n);}return out.toByteArray();}}finally{c.disconnect();}
 }
 private static void verify(Activity a,File file,JSONObject info)throws Exception{
  PackageInfo installed=a.getPackageManager().getPackageInfo(a.getPackageName(),flags());
  PackageInfo next=a.getPackageManager().getPackageArchiveInfo(file.getPath(),flags());
  if(next==null||!a.getPackageName().equals(next.packageName)||version(next)!=info.getLong("version_code")||version(next)<=version(installed)||!certificate(installed).equals(info.getString("certificate_sha256"))||!certificate(installed).equals(certificate(next)))throw new IOException("기존 앱과 업데이트의 서명이 일치하지 않습니다.");
  try(InputStream in=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[16384];int n;while((n=in.read(b))!=-1){if(out.size()+n>40*1024*1024)throw new IOException("업데이트 파일을 확인해주세요.");out.write(b,0,n);}if(!hex(out.toByteArray()).equals(info.getString("sha256")))throw new IOException("업데이트 파일 검증에 실패했습니다. 다시 시도해주세요.");}
 }
 public static synchronized void install(Activity a,String manifest){
  if(busy)return;busy=true;Toast.makeText(a,"업데이트를 내려받고 있습니다.",Toast.LENGTH_SHORT).show();
  new Thread(()->{try{
   JSONObject info=new JSONObject(new String(fetch(manifest+"?t="+System.currentTimeMillis(),32000),StandardCharsets.UTF_8));
   PackageInfo current=a.getPackageManager().getPackageInfo(a.getPackageName(),flags());
   if(info.getLong("version_code")<=version(current)){a.runOnUiThread(()->Toast.makeText(a,"최신 버전입니다.",Toast.LENGTH_SHORT).show());return;}
   byte[] bytes=fetch(info.getString("apk_url"),40*1024*1024);File dir=new File(a.getCacheDir(),"updates");if(!dir.exists()&&!dir.mkdirs())throw new IOException("업데이트 저장 공간을 확인해주세요.");File file=new File(dir,"update.apk");try(FileOutputStream out=new FileOutputStream(file)){out.write(bytes);}verify(a,file,info);
   a.getSharedPreferences("oms_update_install",0).edit().putString("pending",info.toString()).apply();
   a.runOnUiThread(()->{if(a.isFinishing()||a.isDestroyed())return;if(!a.getPackageManager().canRequestPackageInstalls()){
    Toast.makeText(a,"이 앱의 업데이트 설치를 허용해주세요.",Toast.LENGTH_LONG).show();a.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:"+a.getPackageName())));
   }else resume(a);});
  }catch(Exception e){a.runOnUiThread(()->Toast.makeText(a,e.getMessage()==null?"업데이트를 확인하지 못했습니다. 다시 시도해주세요.":e.getMessage(),Toast.LENGTH_LONG).show());}
  finally{synchronized(AppUpdateInstaller.class){busy=false;}}},"oms-update-install").start();
 }
 public static void resume(Activity a){
  String pending=a.getSharedPreferences("oms_update_install",0).getString("pending","");if(pending.isEmpty()||!a.getPackageManager().canRequestPackageInstalls())return;
  a.getSharedPreferences("oms_update_install",0).edit().remove("pending").apply();
  new Thread(()->{try{File file=new File(a.getCacheDir(),"updates/update.apk");verify(a,file,new JSONObject(pending));Uri uri=FileProvider.getUriForFile(a,a.getPackageName()+".updates",file);a.runOnUiThread(()->{if(!a.isFinishing()&&!a.isDestroyed())a.startActivity(new Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));});}catch(Exception e){a.runOnUiThread(()->Toast.makeText(a,"업데이트를 다시 눌러주세요.",Toast.LENGTH_LONG).show());}},"oms-update-verify").start();
 }
 private AppUpdateInstaller(){}
}
