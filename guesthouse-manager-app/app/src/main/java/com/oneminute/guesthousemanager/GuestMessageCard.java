package com.oneminute.guesthousemanager;

import android.app.AlertDialog;
import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import org.json.JSONObject;

/** Presentation only. Data arrives through the already authorized recipient transport. */
final class GuestMessageCard {
 final JSONObject data;final String body;
 private GuestMessageCard(JSONObject data,String body){this.data=data;this.body=body;}
 static GuestMessageCard parse(String json,String message){
  try{if(json==null||json.length()>3000)return null;JSONObject d=new JSONObject(json);String kind=d.optString("kind");if(!kind.equals("online")&&!kind.equals("onsite"))return null;
   String body=message==null?"":message;
   if(kind.equals("online")){body=body.replaceFirst("^\\[OMS-ONLINE:[0-9]+\\]\\s*","");String name=d.optString("guest");if(!name.isEmpty()&&body.startsWith(name+"\n"))body=body.substring(name.length()+1);}
   return new GuestMessageCard(d,body);
  }catch(Exception e){return null;}
 }
 String title(){return data.optString("kind").equals("online")?"온라인 게스트 메세지":"현장 게스트 메세지";}
 static int dp(Context c,int n){return Math.round(n*c.getResources().getDisplayMetrics().density);}
 static GradientDrawable round(int color,int radius,Context c){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(c,radius));return d;}
 static TextView text(Context c,String value,int sp,boolean bold,int color){TextView t=new TextView(c);t.setText(value);t.setTextColor(color);t.setTextSize(sp);t.setTypeface(Typeface.DEFAULT,bold?Typeface.BOLD:Typeface.NORMAL);return t;}
 private static String date(String value){return value.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")?value.substring(5).replace('-','.'):"—";}
 View view(Context c){
  int navy=Color.rgb(28,51,78),muted=Color.rgb(112,128,149);LinearLayout box=new LinearLayout(c);box.setOrientation(1);box.setPadding(dp(c,12),dp(c,12),dp(c,12),dp(c,12));box.setBackground(round(Color.rgb(244,247,252),18,c));
  LinearLayout strip=new LinearLayout(c);strip.setOrientation(1);strip.setPadding(dp(c,8),dp(c,7),dp(c,8),dp(c,7));strip.setBackground(round(Color.rgb(226,237,252),9,c));
  LinearLayout top=new LinearLayout(c);top.setGravity(Gravity.CENTER_VERTICAL);String room=data.optString("room","객실 미정");if(room.matches("[0-9]+"))room+="호";
  boolean wide=c.getResources().getDisplayMetrics().widthPixels/c.getResources().getDisplayMetrics().density/c.getResources().getConfiguration().fontScale>=380;
  String stay="체크인 "+date(data.optString("arrival"))+" → 체크아웃 "+date(data.optString("departure"));
  top.addView(text(c,room,12,true,navy),new LinearLayout.LayoutParams(wide?-2:0,-2,wide?0:1));if(wide){TextView dates=text(c,stay,10,false,muted);dates.setPadding(dp(c,5),0,dp(c,3),0);top.addView(dates,new LinearLayout.LayoutParams(0,-2,1));}top.addView(text(c,data.optString("property"),12,true,navy),new LinearLayout.LayoutParams(-2,-2));
  String channel=data.optString("kind").equals("online")?data.optString("channel"):"";
  if(!channel.isEmpty()){ChannelIcon icon=new ChannelIcon(c,channel);LinearLayout.LayoutParams ip=new LinearLayout.LayoutParams(dp(c,24),dp(c,24));ip.setMargins(dp(c,5),0,0,0);top.addView(icon,ip);}
  strip.addView(top,new LinearLayout.LayoutParams(-1,-2));if(!wide){TextView dates=text(c,stay,11,false,muted);dates.setPadding(0,dp(c,3),0,0);strip.addView(dates,new LinearLayout.LayoutParams(-1,-2));}box.addView(strip,new LinearLayout.LayoutParams(-1,-2));
  TextView guest=text(c,data.optString("guest","게스트"),18,true,navy);guest.setPadding(0,dp(c,10),0,dp(c,5));box.addView(guest,new LinearLayout.LayoutParams(-1,-2));
  TextView message=text(c,body.isEmpty()?"메세지 메뉴에서 확인해주세요.":body,16,false,navy);message.setLineSpacing(dp(c,3),1);box.addView(message,new LinearLayout.LayoutParams(-1,-2));
  String time=data.optString("sent");if(!time.isEmpty()){TextView received=text(c,time,10,false,muted);received.setGravity(Gravity.RIGHT);received.setPadding(0,dp(c,9),0,0);box.addView(received,new LinearLayout.LayoutParams(-1,-2));}
  return box;
 }
 static String channelName(String source){String s=source.toLowerCase(java.util.Locale.ROOT);if(s.contains("airbnb"))return "에어비앤비";if(s.contains("booking"))return "부킹닷컴";if(s.contains("agoda"))return "아고다";if(s.contains("expedia"))return "익스피디아";if(s.contains("direct"))return "다이렉트 예약";return source;}
 static final class ChannelIcon extends View {
  final String name;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
  ChannelIcon(Context c,String source){super(c);name=channelName(source);setContentDescription(name);setFocusable(true);setOnClickListener(v->new AlertDialog.Builder(c).setMessage(name).setPositiveButton("확인",null).show());}
  void color(int c){paint.setColor(c);paint.setStyle(Paint.Style.FILL);}
  @Override protected void onDraw(Canvas original){super.onDraw(original);Canvas c=original;c.save();c.scale(getWidth()/32f,getHeight()/32f);color(name.equals("에어비앤비")?0xffff385c:name.equals("부킹닷컴")?0xff003b80:Color.WHITE);c.drawRoundRect(.6f,.6f,31.4f,31.4f,7,7,paint);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(1.2f);paint.setColor(0xffb9b9b9);c.drawRoundRect(.6f,.6f,31.4f,31.4f,7,7,paint);
   if(name.equals("에어비앤비")){Path p=new Path();p.moveTo(16,23.6f);p.cubicTo(12.2f,27.5f,8.6f,27.6f,7,25.3f);p.cubicTo(5.6f,23.3f,7.2f,20.3f,8.5f,17.5f);p.lineTo(12.7f,8.3f);p.cubicTo(13.6f,6.4f,14.6f,5.3f,16,5.3f);p.cubicTo(17.4f,5.3f,18.4f,6.4f,19.3f,8.3f);p.lineTo(23.5f,17.5f);p.cubicTo(24.8f,20.3f,26.4f,23.3f,25,25.3f);p.cubicTo(23.4f,27.6f,19.8f,27.5f,16,23.6f);p.cubicTo(13.8f,21.2f,11.8f,18.6f,11.8f,16.5f);p.cubicTo(11.8f,10.9f,20.2f,10.9f,20.2f,16.5f);p.cubicTo(20.2f,18.6f,18.2f,21.2f,16,23.6f);paint.setColor(Color.WHITE);paint.setStrokeWidth(1.65f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);c.drawPath(p,paint);
   }else if(name.equals("아고다")){paint.setColor(0xff555555);paint.setStrokeWidth(3.2f);c.drawCircle(15.5f,12.7f,7,paint);c.drawLine(22.5f,12.7f,22.5f,20,paint);int[] colors={0xffff2943,0xffffc400,0xff00ba72,0xffba329c,0xff00afd2};for(int i=0;i<5;i++){color(colors[i]);c.drawCircle(7+i*4.5f,26.2f,1.8f,paint);}
   }else{color(name.equals("부킹닷컴")?Color.WHITE:name.equals("익스피디아")?0xff0064ed:0xff24856c);paint.setTypeface(Typeface.create("sans-serif",Typeface.BOLD));paint.setTextSize(name.equals("익스피디아")?33:24);paint.setTextAlign(Paint.Align.CENTER);String letter=name.equals("부킹닷컴")?"B":name.equals("익스피디아")?"e":name.equals("다이렉트 예약")?"D":name.substring(0,name.offsetByCodePoints(0,1));c.drawText(letter,name.equals("부킹닷컴")?14:16,25,paint);if(name.equals("부킹닷컴")){color(0xff00aeef);c.drawCircle(25,23,2.2f,paint);}}
   c.restore();
  }
 }
}
