package com.oneminute.guesthousemanager;

import android.app.*;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.text.InputFilter;
import android.text.TextUtils;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.time.Instant;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.IntConsumer;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

/** Small anchored menus; only the final confirmation creates a server reservation. */
final class NativeStaffSchedule {
 interface Draft { JSONObject data() throws Exception; File file(); String mime(); void accepted(JSONObject snapshot,File file); }
 private final Activity activity;private final NativeStaffChatApi api;private final String peer;private final Draft draft;private final IntConsumer countChanged;
 private final ExecutorService worker=Executors.newSingleThreadExecutor();
 private Dialog dialog;private PopupWindow popup;private TextView error;private boolean busy,closed,refreshing;private long refreshed;private View anchor;
 NativeStaffSchedule(Activity a,NativeStaffChatApi api,String peer,Draft draft,IntConsumer countChanged){this.activity=a;this.api=api;this.peer=peer;this.draft=draft;this.countChanged=countChanged;}
 void refresh(boolean force){
  if(closed||refreshing||busy||!force&&System.currentTimeMillis()-refreshed<30000)return;refreshing=true;
  worker.execute(()->{try{JSONObject r=api.chat("schedule_list",new JSONObject().put("peer",peer));activity.runOnUiThread(()->{if(closed)return;refreshing=false;refreshed=System.currentTimeMillis();publishCount(r);});}catch(Exception ex){activity.runOnUiThread(()->refreshing=false);}});
 }
 private void publishCount(JSONObject result){JSONArray items=result.optJSONArray("items");if(items!=null)countChanged.accept(items.length());}
 private LinearLayout columnBox(){LinearLayout b=column(activity);b.setPadding(dp(activity,16),dp(activity,10),dp(activity,16),dp(activity,12));return b;}
 private void dismiss(){if(popup!=null)popup.dismiss();if(dialog!=null)dialog.dismiss();}
 private void showPopup(LinearLayout box,View target,int width){
  dismiss();anchor=target;int[] at=new int[2];target.getLocationOnScreen(at);Rect visible=new Rect();target.getWindowVisibleDisplayFrame(visible);
  int w=Math.min(dp(activity,width),visible.width()-dp(activity,24));box.measure(View.MeasureSpec.makeMeasureSpec(w,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(0,View.MeasureSpec.UNSPECIFIED));
  int h=Math.min(box.getMeasuredHeight(),Math.max(dp(activity,100),at[1]-visible.top-dp(activity,16)));
  ScrollView scroll=new ScrollView(activity);scroll.setFillViewport(false);scroll.addView(box);scroll.setClipToOutline(true);scroll.setBackground(background(Color.WHITE,16,activity));
  popup=new PopupWindow(scroll,w,h,true);popup.setBackgroundDrawable(background(Color.WHITE,16,activity));popup.setElevation(dp(activity,12));popup.setOutsideTouchable(true);popup.setInputMethodMode(PopupWindow.INPUT_METHOD_NOT_NEEDED);
  int x=Math.max(visible.left+dp(activity,12),Math.min(at[0]+target.getWidth()-w,visible.right-w-dp(activity,12))),y=Math.max(visible.top+dp(activity,8),at[1]-h-dp(activity,8));
  popup.showAtLocation(target,Gravity.TOP|Gravity.LEFT,x,y);
 }
 private void divider(LinearLayout box){View line=new View(activity);line.setBackgroundColor(0xffe8edf3);box.addView(line,new LinearLayout.LayoutParams(-1,dp(activity,1)));}
 private LinearLayout menuRow(LinearLayout box,String label,boolean person,Runnable click){
  LinearLayout row=row(activity);row.setMinimumHeight(dp(activity,48));row.setPadding(0,dp(activity,6),0,dp(activity,6));ImageView icon=new ImageView(activity);icon.setImageDrawable(new Glyph(person,false));row.addView(icon,new LinearLayout.LayoutParams(dp(activity,23),dp(activity,23)));TextView text=text(activity,label,15,INK);text.setPadding(dp(activity,12),0,0,0);row.addView(text,new LinearLayout.LayoutParams(0,-2,1));row.setContentDescription(label);row.setFocusable(true);row.setOnClickListener(v->{if(!busy)click.run();});box.addView(row);return row;
 }
 void open(View target){
  if(closed||busy)return;
  try{JSONObject snapshot=draft.data();if(snapshot.optString("body").trim().isEmpty())return;File file=draft.file();String type=draft.mime();LinearLayout box=columnBox();menuRow(box,"날짜·시간 예약",false,()->prepare(null,snapshot,file,type,"time"));divider(box);menuRow(box,"근무자 출근 시",true,()->prepare(null,snapshot,file,type,"checkin"));showPopup(box,target,228);}catch(Exception ignored){}
 }
 private LinearLayout editor(String name){
  dismiss();dialog=new Dialog(activity);ScrollView scroll=new ScrollView(activity);LinearLayout box=columnBox();box.setPadding(dp(activity,20),dp(activity,12),dp(activity,20),dp(activity,18));scroll.addView(box);dialog.setContentView(scroll);
  LinearLayout head=row(activity);TextView title=text(activity,name,18,INK);title.setTypeface(null,Typeface.BOLD);head.addView(title,new LinearLayout.LayoutParams(0,-2,1));TextView close=button(activity,"×","닫기");close.setBackgroundColor(Color.TRANSPARENT);head.addView(close,new LinearLayout.LayoutParams(dp(activity,36),dp(activity,40)));close.setOnClickListener(v->{if(!busy)dialog.dismiss();});box.addView(head);
  error=text(activity,"",12,0xffb74848);error.setVisibility(View.GONE);box.addView(error);dialog.getWindow().setBackgroundDrawable(background(Color.WHITE,18,activity));dialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);dialog.show();dialog.getWindow().setLayout(Math.min(dp(activity,340),activity.getResources().getDisplayMetrics().widthPixels-dp(activity,32)),-2);return box;
 }
 private void fail(String message){error.setVisibility(View.VISIBLE);error.setText(message);}
 private TextView action(LinearLayout box,String label,Runnable click){TextView b=button(activity,label,label);b.setTextSize(14);b.setBackground(background(0xfff0f5fa,10,activity));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(activity,42));p.topMargin=dp(activity,10);box.addView(b,p);b.setOnClickListener(v->{if(!busy)click.run();});return b;}
 private void async(Callable<JSONObject> task,java.util.function.Consumer<JSONObject> done){
  if(busy||closed)return;busy=true;if(dialog!=null)dialog.setCancelable(false);fail("처리 중…");
  worker.execute(()->{try{JSONObject result=task.call();activity.runOnUiThread(()->{if(closed)return;busy=false;if(dialog!=null)dialog.setCancelable(true);error.setVisibility(View.GONE);publishCount(result);done.accept(result);});}catch(Exception ex){activity.runOnUiThread(()->{if(closed)return;busy=false;if(dialog!=null)dialog.setCancelable(true);fail(ex.getMessage()==null?"예약을 처리하지 못했습니다. 다시 시도해주세요.":ex.getMessage());});}});
 }
 private void prepare(JSONObject item,JSONObject snapshot,File file,String type,String mode){editor("time".equals(mode)?"날짜·시간 예약":"근무자 출근 시");async(()->api.chat("schedule_list",new JSONObject().put("peer",peer)),r->edit(item,snapshot,file,type,r.optJSONArray("recipients"),mode));}
 void list(View target){
  if(closed||busy)return;LinearLayout loading=columnBox();error=text(activity,"불러오는 중…",13,MUTED);loading.addView(error);showPopup(loading,target,320);
  async(()->api.chat("schedule_list",new JSONObject().put("peer",peer)),r->{if(popup==null||!popup.isShowing())return;LinearLayout box=columnBox();JSONArray items=r.optJSONArray("items");TextView heading=text(activity,"예약 메시지  "+(items==null?0:items.length()),16,INK);heading.setTypeface(null,Typeface.BOLD);heading.setPadding(0,dp(activity,4),0,dp(activity,12));box.addView(heading);divider(box);
   if(items==null||items.length()==0)box.addView(text(activity,"예약된 메시지가 없습니다.",13,MUTED));else for(int i=0;i<items.length();i++){JSONObject item=items.optJSONObject(i);if(item==null)continue;LinearLayout row=row(activity);row.setPadding(0,dp(activity,12),0,dp(activity,12));ImageView icon=new ImageView(activity);boolean on="checkin".equals(item.optString("mode"));icon.setImageDrawable(new Glyph(on,false));row.addView(icon,new LinearLayout.LayoutParams(dp(activity,22),dp(activity,22)));LinearLayout labels=column(activity);labels.setPadding(dp(activity,12),0,dp(activity,8),0);TextView time=text(activity,on?"다음 출근 시 · "+item.optString("trigger_name","근무자"):format(item.optString("send_at")),14,INK);time.setTypeface(null,Typeface.BOLD);time.setMaxLines(1);time.setEllipsize(TextUtils.TruncateAt.END);labels.addView(time);TextView body=text(activity,item.optString("body"),13,MUTED);body.setMaxLines(2);body.setEllipsize(TextUtils.TruncateAt.END);body.setPadding(0,dp(activity,4),0,0);labels.addView(body);if("failed".equals(item.optString("status")))labels.addView(text(activity,"발송 실패 · "+item.optString("error"),12,0xffb74848));row.addView(labels,new LinearLayout.LayoutParams(0,-2,1));row.addView(text(activity,"›",22,MUTED));row.setTag("scheduled-item-"+item.optString("id"));row.setContentDescription("예약 내용 보기: "+item.optString("body"));row.setFocusable(true);row.setOnClickListener(v->edit(item,item,null,"",r.optJSONArray("recipients"),item.optString("mode","time")));box.addView(row);if(i<items.length()-1)divider(box);}showPopup(box,target,320);
  });
 }
 private String format(String timestamp){try{return new SimpleDateFormat("M월 d일 (E) HH:mm",Locale.KOREA).format(Date.from(Instant.parse(timestamp)));}catch(Exception ignored){return timestamp;}}
 private void edit(JSONObject item,JSONObject snapshot,File file,String type,JSONArray recipients,String initialMode){
  LinearLayout box=editor(item==null?("checkin".equals(initialMode)?"근무자 출근 시":"날짜·시간 예약"):"예약 메시지 수정");String client=UUID.randomUUID().toString();EditText body=new EditText(activity);body.setText(snapshot.optString("body"));body.setTextSize(14);body.setTextColor(INK);body.setMinLines(1);body.setMaxLines(4);body.setPadding(dp(activity,12),dp(activity,10),dp(activity,12),dp(activity,10));body.setBackground(background(0xfff5f8fc,10,activity));body.setFilters(new InputFilter[]{new InputFilter.LengthFilter(2000)});body.setContentDescription("예약 메시지 내용");box.addView(body);
  if(file!=null||item!=null&&!item.isNull("attachment_mime"))box.addView(text(activity,"첨부 파일 포함",12,MUTED));
  List<String> names=new ArrayList<>(),ids=new ArrayList<>();if(recipients!=null)for(int i=0;i<recipients.length();i++){JSONObject p=recipients.optJSONObject(i);if(p!=null){names.add(p.optString("name","근무자"));ids.add(p.optString("id"));}}
  final boolean[] on={"checkin".equals(initialMode)};
  LinearLayout modeRow=row(activity);TextView time=button(activity,"날짜·시간","날짜·시간"),checkin=button(activity,"출근 시","출근 시");modeRow.addView(time,new LinearLayout.LayoutParams(0,dp(activity,36),1));modeRow.addView(checkin,new LinearLayout.LayoutParams(0,dp(activity,36),1));if(item!=null)box.addView(modeRow);checkin.setEnabled(!ids.isEmpty());
  Calendar chosen=Calendar.getInstance();chosen.setTimeInMillis(((System.currentTimeMillis()+1800000)/60000)*60000);if(item!=null&&!item.isNull("send_at"))try{chosen.setTimeInMillis(Instant.parse(item.getString("send_at")).toEpochMilli());}catch(Exception ignored){}
  TextView when=action(box,format(chosen.toInstant().toString()),()->new DatePickerDialog(activity,(v,y,m,d)->{chosen.set(y,m,d);new TimePickerDialog(activity,(view,h,min)->{chosen.set(Calendar.HOUR_OF_DAY,h);chosen.set(Calendar.MINUTE,min);chosen.set(Calendar.SECOND,0);chosen.set(Calendar.MILLISECOND,0);TextView label=box.findViewWithTag("schedule-date");label.setText(format(chosen.toInstant().toString()));},chosen.get(Calendar.HOUR_OF_DAY),chosen.get(Calendar.MINUTE),true).show();},chosen.get(Calendar.YEAR),chosen.get(Calendar.MONTH),chosen.get(Calendar.DAY_OF_MONTH)).show());when.setTag("schedule-date");
  TextView zone=text(activity,"기기 시간 · "+TimeZone.getDefault().getID(),11,MUTED);zone.setPadding(0,dp(activity,4),0,0);box.addView(zone);
  Spinner people=new Spinner(activity);people.setContentDescription("출근 기준 근무자");people.setAdapter(new ArrayAdapter<>(activity,android.R.layout.simple_spinner_dropdown_item,names));box.addView(people,new LinearLayout.LayoutParams(-1,dp(activity,42)));if(item!=null&&ids.contains(item.optString("trigger_employee_id")))people.setSelection(ids.indexOf(item.optString("trigger_employee_id")));
  TextView hint=text(activity,ids.isEmpty()?"수신자에 근무자가 없어 출근 예약을 사용할 수 없습니다.":"다음 출근보고 완료 후 이 대화에 전달합니다.",12,MUTED);box.addView(hint);
  Runnable toggle=()->{when.setVisibility(on[0]?View.GONE:View.VISIBLE);zone.setVisibility(on[0]?View.GONE:View.VISIBLE);people.setVisibility(on[0]&&!ids.isEmpty()?View.VISIBLE:View.GONE);hint.setVisibility(on[0]?View.VISIBLE:View.GONE);time.setBackground(background(on[0]?0xfff5f8fc:0xffe5effc,8,activity));checkin.setBackground(background(on[0]?0xffe5effc:0xfff5f8fc,8,activity));};time.setOnClickListener(v->{if(!busy){on[0]=false;toggle.run();}});checkin.setOnClickListener(v->{if(!busy){on[0]=true;toggle.run();}});toggle.run();
  TextView save=action(box,item==null?"예약하기":"예약 변경",()->{try{if(body.getText().toString().trim().isEmpty())throw new Exception("메시지 내용을 입력해주세요.");if(on[0]&&ids.isEmpty())throw new Exception("출근 기준 근무자가 없습니다.");if(!on[0]&&chosen.getTimeInMillis()<=System.currentTimeMillis())throw new Exception("현재 이후 시간을 선택해주세요.");JSONObject data=new JSONObject().put("peer",peer).put("client_id",client).put("body",body.getText().toString().trim()).put("priority",snapshot.optString("priority","normal")).put("mode",on[0]?"checkin":"time").put("send_at",on[0]?JSONObject.NULL:chosen.toInstant().toString()).put("trigger_employee_id",on[0]?ids.get(people.getSelectedItemPosition()):JSONObject.NULL);if(item!=null)data.put("id",item.getString("id")).put("revision",item.getInt("revision"));async(()->{if(item==null)attachment(data,file,type);return api.chat(item==null?"schedule_create":"schedule_update",data);},r->{if(item==null)draft.accepted(snapshot,file);dialog.dismiss();refresh(true);Toast.makeText(activity,"예약되었습니다.",Toast.LENGTH_SHORT).show();});}catch(Exception ex){fail(ex.getMessage());}});save.setTextColor(Color.WHITE);save.setBackground(background(BLUE,10,activity));
  if(item!=null){TextView cancel=action(box,"예약 취소",()->new AlertDialog.Builder(activity).setMessage("이 메시지의 예약을 취소할까요?").setNegativeButton("유지",null).setPositiveButton("예약 취소",(d,w)->async(()->api.chat("schedule_cancel",new JSONObject().put("peer",peer).put("id",item.getString("id")).put("revision",item.getInt("revision"))),r->{dialog.dismiss();refresh(true);})).show());cancel.setTextColor(0xffb74848);cancel.setBackgroundColor(Color.TRANSPARENT);}
 }
 static final class Glyph extends Drawable {
  private final boolean person,dot;private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
  Glyph(boolean person,boolean dot){this.person=person;this.dot=dot;}
  @Override public void draw(Canvas canvas){Rect b=getBounds();float side=Math.min(b.width(),b.height());canvas.save();canvas.translate(b.exactCenterX()-side/2,b.exactCenterY()-side/2);canvas.scale(side/26f,side/26f);paint.setColor(INK);paint.setStrokeWidth(1.6f);paint.setStyle(Paint.Style.STROKE);paint.setStrokeCap(Paint.Cap.ROUND);if(person){canvas.drawCircle(13,7,4,paint);canvas.drawRoundRect(4,14,22,24,7,7,paint);}else{canvas.drawRoundRect(3,5,22,23,3,3,paint);canvas.drawLine(3,10,22,10,paint);canvas.drawLine(8,2,8,7,paint);canvas.drawLine(17,2,17,7,paint);if(dot){paint.setStyle(Paint.Style.FILL);paint.setColor(Color.WHITE);canvas.drawCircle(22,22,4,paint);paint.setColor(0xffe65359);canvas.drawCircle(22,22,2.8f,paint);}}canvas.restore();}
  @Override public void setAlpha(int a){paint.setAlpha(a);}@Override public void setColorFilter(ColorFilter f){paint.setColorFilter(f);}@Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
 }
 private void attachment(JSONObject data,File file,String mime)throws Exception{
  if(file==null)return;if(!file.isFile()||file.length()>20971520)throw new IOException("첨부 파일을 확인해주세요.");
  if(mime.startsWith("video/")){int total=(int)((file.length()+1048575)/1048576);long deadline=System.nanoTime()+TimeUnit.MINUTES.toNanos(3);try(DataInputStream in=new DataInputStream(new FileInputStream(file))){for(int part=0;part<total;part++){if(closed||Thread.currentThread().isInterrupted()||System.nanoTime()>deadline)throw new IOException("예약 업로드가 중단되었습니다. 다시 시도해주세요.");byte[] bytes=new byte[(int)Math.min(1048576,file.length()-(long)part*1048576)];in.readFully(bytes);api.rpc("staff_chat_upload_chunk",new JSONObject().put("p_client_id",data.getString("client_id")).put("p_peer",peer).put("p_mime_type",mime).put("p_part_index",part).put("p_total_parts",total).put("p_chunk",android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP)));}}data.put("uploaded",true);
  }else{byte[] bytes=new byte[(int)file.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(file))){in.readFully(bytes);}data.put("photo","data:"+mime+";base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP));}
 }
 void close(){closed=true;dismiss();worker.shutdownNow();}
}
