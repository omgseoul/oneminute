package com.oneminute.guesthousemanager;

import android.app.*;
import android.graphics.Color;
import android.text.InputFilter;
import android.view.*;
import android.widget.*;
import com.google.android.material.bottomsheet.BottomSheetDialog;
import org.json.*;
import java.io.*;
import java.time.Instant;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.*;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

/** Staff scheduling uses the server queue; opening a sheet never sends a message. */
final class NativeStaffSchedule {
 interface Draft { JSONObject data() throws Exception; File file(); String mime(); void accepted(); }
 private final Activity activity;private final NativeStaffChatApi api;private final String peer;private final Draft draft;
 private final ExecutorService worker=Executors.newSingleThreadExecutor();
 private BottomSheetDialog dialog;private TextView error;private boolean busy,closed;
 NativeStaffSchedule(Activity activity,NativeStaffChatApi api,String peer,Draft draft){this.activity=activity;this.api=api;this.peer=peer;this.draft=draft;}
 private LinearLayout sheet(String name){
  if(dialog!=null)dialog.dismiss();dialog=new BottomSheetDialog(activity);ScrollView scroll=new ScrollView(activity);LinearLayout box=column(activity);box.setPadding(dp(activity,22),dp(activity,18),dp(activity,22),dp(activity,24));scroll.addView(box);dialog.setContentView(scroll);
  LinearLayout head=row(activity);TextView title=text(activity,name,20,INK);title.setTypeface(null,android.graphics.Typeface.BOLD);head.addView(title,new LinearLayout.LayoutParams(0,-2,1));TextView close=button(activity,"×","닫기");head.addView(close,new LinearLayout.LayoutParams(dp(activity,44),dp(activity,44)));close.setOnClickListener(v->{if(!busy)dialog.dismiss();});box.addView(head);
  error=text(activity,"",13,0xffb74848);box.addView(error);dialog.show();return box;
 }
 private TextView action(LinearLayout box,String label,Runnable click){TextView b=button(activity,label,label);b.setTextSize(15);b.setBackground(background(0xfff0f5fa,12,activity));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(activity,46));p.topMargin=dp(activity,10);box.addView(b,p);b.setOnClickListener(v->{if(!busy)click.run();});return b;}
 private void async(Callable<JSONObject> task,java.util.function.Consumer<JSONObject> done){
  if(busy||closed)return;busy=true;dialog.setCancelable(false);error.setText("처리 중…");
  worker.execute(()->{try{JSONObject result=task.call();activity.runOnUiThread(()->{if(closed)return;busy=false;dialog.setCancelable(true);error.setText("");done.accept(result);});}catch(Exception ex){activity.runOnUiThread(()->{if(closed)return;busy=false;dialog.setCancelable(true);error.setText(ex.getMessage()==null?"예약을 처리하지 못했습니다. 다시 시도해주세요.":ex.getMessage());});}});
 }
 void open(){try{JSONObject data=draft.data();if(data.optString("body").trim().isEmpty())return;File file=draft.file();String type=draft.mime();sheet("예약 메시지");async(()->api.chat("schedule_list",new JSONObject().put("peer",peer)),r->edit(null,data,file,type,r.optJSONArray("recipients")));}catch(Exception ignored){}}
 void list(){LinearLayout box=sheet("예약 메시지");async(()->api.chat("schedule_list",new JSONObject().put("peer",peer)),r->{JSONArray items=r.optJSONArray("items");if(items==null||items.length()==0){box.addView(text(activity,"예약된 메시지가 없습니다.",14,MUTED));return;}for(int i=0;i<items.length();i++){JSONObject item=items.optJSONObject(i);if(item==null)continue;String when="checkin".equals(item.optString("mode"))?item.optString("trigger_name","근무자")+" · 다음 출근보고 완료 시":format(item.optString("send_at"));TextView title=text(activity,when,14,BLUE);title.setPadding(0,dp(activity,18),0,dp(activity,8));box.addView(title);box.addView(text(activity,item.optString("body"),15,INK));if(!item.isNull("attachment_mime"))box.addView(text(activity,"첨부 파일 포함",12,MUTED));if("failed".equals(item.optString("status")))box.addView(text(activity,"발송 실패 · "+item.optString("error"),13,0xffb74848));action(box,"수정",()->edit(item,item,null,"",r.optJSONArray("recipients")));action(box,"예약 취소",()->new AlertDialog.Builder(activity).setMessage("이 메시지의 예약을 취소할까요?").setNegativeButton("유지",null).setPositiveButton("예약 취소",(d,w)->async(()->api.chat("schedule_cancel",new JSONObject().put("peer",peer).put("id",item.getString("id")).put("revision",item.getInt("revision"))),ignored->list())).show());}});}
 private String format(String timestamp){try{return new SimpleDateFormat("M월 d일 (E) HH:mm",Locale.KOREA).format(Date.from(Instant.parse(timestamp)));}catch(Exception ignored){return timestamp;}}
 private void edit(JSONObject item,JSONObject snapshot,File file,String type,JSONArray recipients){
  LinearLayout box=sheet(item==null?"예약 메시지":"예약 메시지 수정");String client=UUID.randomUUID().toString();EditText body=new EditText(activity);body.setText(snapshot.optString("body"));body.setTextSize(15);body.setMinLines(2);body.setMaxLines(5);body.setFilters(new InputFilter[]{new InputFilter.LengthFilter(2000)});body.setContentDescription("예약 메시지 내용");box.addView(body);
  if(file!=null||item!=null&&!item.isNull("attachment_mime"))box.addView(text(activity,"첨부 파일 포함",12,MUTED));
  RadioGroup modes=new RadioGroup(activity);RadioButton time=new RadioButton(activity),checkin=new RadioButton(activity);time.setId(View.generateViewId());checkin.setId(View.generateViewId());time.setText("◷ 날짜·시간 예약");checkin.setText("근무자 출근 시");modes.addView(time);modes.addView(checkin);box.addView(modes);time.setChecked(true);
  Calendar chosen=Calendar.getInstance();chosen.setTimeInMillis(((System.currentTimeMillis()+1800000)/60000)*60000);if(item!=null&&!item.isNull("send_at"))try{chosen.setTimeInMillis(Instant.parse(item.getString("send_at")).toEpochMilli());}catch(Exception ignored){}
  TextView when=action(box,format(chosen.toInstant().toString()),()->new DatePickerDialog(activity,(v,y,m,d)->{chosen.set(y,m,d);new TimePickerDialog(activity,(view,h,min)->{chosen.set(Calendar.HOUR_OF_DAY,h);chosen.set(Calendar.MINUTE,min);chosen.set(Calendar.SECOND,0);chosen.set(Calendar.MILLISECOND,0);refreshDate(box,chosen);},chosen.get(Calendar.HOUR_OF_DAY),chosen.get(Calendar.MINUTE),true).show();},chosen.get(Calendar.YEAR),chosen.get(Calendar.MONTH),chosen.get(Calendar.DAY_OF_MONTH)).show());when.setTag("schedule-date");
  TextView zone=text(activity,"기기 시간 기준 · "+TimeZone.getDefault().getID(),12,MUTED);box.addView(zone);
  List<String> names=new ArrayList<>(),ids=new ArrayList<>();if(recipients!=null)for(int i=0;i<recipients.length();i++){JSONObject p=recipients.optJSONObject(i);if(p!=null){names.add(p.optString("name","근무자"));ids.add(p.optString("id"));}}
  Spinner people=new Spinner(activity);people.setContentDescription("출근 기준 근무자");people.setAdapter(new ArrayAdapter<>(activity,android.R.layout.simple_spinner_dropdown_item,names));box.addView(people,new LinearLayout.LayoutParams(-1,dp(activity,48)));TextView hint=text(activity,ids.isEmpty()?"수신자에 근무자가 있는 대화에서 출근 시 전달을 사용할 수 있습니다.":"선택한 근무자의 다음 출근보고가 완료되면 이 채팅방으로 전달합니다.",12,MUTED);box.addView(hint);checkin.setEnabled(!ids.isEmpty());people.setVisibility(View.GONE);
  modes.setOnCheckedChangeListener((g,id)->{boolean on=id==checkin.getId();when.setVisibility(on?View.GONE:View.VISIBLE);zone.setVisibility(on?View.GONE:View.VISIBLE);people.setVisibility(on?View.VISIBLE:View.GONE);});
  if(item!=null&&"checkin".equals(item.optString("mode"))&&ids.contains(item.optString("trigger_employee_id"))){checkin.setChecked(true);people.setSelection(ids.indexOf(item.optString("trigger_employee_id")));}
  action(box,item==null?"예약하기":"예약 변경",()->{try{boolean on=checkin.isChecked();if(body.getText().toString().trim().isEmpty())throw new Exception("메시지 내용을 입력해주세요.");if(!on&&chosen.getTimeInMillis()<=System.currentTimeMillis())throw new Exception("현재 이후 시간을 선택해주세요.");JSONObject data=new JSONObject().put("peer",peer).put("client_id",client).put("body",body.getText().toString().trim()).put("priority",snapshot.optString("priority","normal")).put("mode",on?"checkin":"time").put("send_at",on?JSONObject.NULL:chosen.toInstant().toString()).put("trigger_employee_id",on?ids.get(people.getSelectedItemPosition()):JSONObject.NULL);if(item!=null)data.put("id",item.getString("id")).put("revision",item.getInt("revision"));async(()->{if(item==null)attachment(data,file,type);return api.chat(item==null?"schedule_create":"schedule_update",data);},r->{if(item==null)draft.accepted();dialog.dismiss();Toast.makeText(activity,"예약되었습니다. 예약 목록에서 수정·취소할 수 있습니다.",Toast.LENGTH_LONG).show();});}catch(Exception ex){error.setText(ex.getMessage());}});
 }
 private void refreshDate(LinearLayout box,Calendar chosen){TextView when=box.findViewWithTag("schedule-date");if(when!=null)when.setText(format(chosen.toInstant().toString()));}
 private void attachment(JSONObject data,File file,String mime)throws Exception{
  if(file==null)return;if(!file.isFile()||file.length()>20971520)throw new IOException("첨부 파일을 확인해주세요.");
  if(mime.startsWith("video/")){int total=(int)((file.length()+1048575)/1048576);long deadline=System.nanoTime()+TimeUnit.MINUTES.toNanos(3);try(DataInputStream in=new DataInputStream(new FileInputStream(file))){for(int part=0;part<total;part++){if(closed||Thread.currentThread().isInterrupted()||System.nanoTime()>deadline)throw new IOException("예약 업로드가 중단되었습니다. 다시 시도해주세요.");byte[] bytes=new byte[(int)Math.min(1048576,file.length()-(long)part*1048576)];in.readFully(bytes);api.rpc("staff_chat_upload_chunk",new JSONObject().put("p_client_id",data.getString("client_id")).put("p_peer",peer).put("p_mime_type",mime).put("p_part_index",part).put("p_total_parts",total).put("p_chunk",android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP)));}}data.put("uploaded",true);
  }else{byte[] bytes=new byte[(int)file.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(file))){in.readFully(bytes);}data.put("photo","data:"+mime+";base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP));}
 }
 void close(){closed=true;if(dialog!=null)dialog.dismiss();worker.shutdownNow();}
}
