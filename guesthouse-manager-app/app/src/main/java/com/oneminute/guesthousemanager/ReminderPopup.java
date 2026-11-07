package com.oneminute.guesthousemanager;

import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.regex.*;

/** Human-readable reminder payload, shared with reminder-popup.js. */
final class ReminderPopup {
 final boolean calendar,overdue;
 final String heading,timing,title,dateLine,guidance,button,path;
 private ReminderPopup(boolean calendar,boolean overdue,String timing,String title,String dateLine){
  this.calendar=calendar;this.overdue=overdue;this.timing=timing;this.title=title;this.dateLine=dateLine;
  heading=overdue?"지연된 업무":calendar?"일정 알림":"To do 알림";
  guidance=overdue?"기한이 지났습니다. 지금 확인해주세요.":calendar?"예정된 일정을 확인해주세요.":"할 일을 확인하고 완료해주세요.";
  button=calendar?"일정 보기":"할 일 보기";path=calendar?"calendar.html":"mission.html";
 }
 static ReminderPopup parse(String message,String sender){return parse(message,sender,Instant.now());}
 static ReminderPopup parse(String message,String sender,Instant now){
  String[] lines=(message==null?"":message).replace("\\n","\n").split("\n",-1);
  int first=0;String category=lines[0].trim();
  if(category.equals("To do 알림")||category.equals("일정 알림"))first=1;
  else if("To do 알림".equals(sender)||"일정 알림".equals(sender))category=sender;else return null;
  boolean calendar=category.equals("일정 알림"),overdue=false;Long days=null;
  String title=first<lines.length?lines[first]:"",date="",zone="Asia/Seoul";
  Matcher prefix=Pattern.compile("^(?:(\\d+)일 (지연|후)|오늘|내일|지연|등록):\\s*").matcher(title);
  if(prefix.find()){
   String tag=prefix.group();overdue=!calendar&&tag.contains("지연");
   if(prefix.group(1)!=null){try{days=Long.parseLong(prefix.group(1))*("지연".equals(prefix.group(2))?-1:1);}catch(NumberFormatException ignored){}}
   else if(tag.startsWith("오늘"))days=0L;else if(tag.startsWith("내일"))days=1L;
   title=title.substring(prefix.end());
  }
  for(int i=first+1;i<lines.length;i++){if(lines[i].matches("^(마감|일정): \\d{4}-\\d{2}-\\d{2} .*"))date=lines[i];if(lines[i].startsWith("시간대: "))zone=lines[i].substring(5);}
  if(!date.isEmpty())try{days=ChronoUnit.DAYS.between(now.atZone(ZoneId.of(zone)).toLocalDate(),LocalDate.parse(date.substring(4,14)));overdue=!calendar&&days<0;}catch(RuntimeException ignored){}
  String timing=days==null?"":days==0?"(오늘)":days<0?(overdue?"("+(-days)+"일 지연)":"(지난 일정)"):"("+days+"일 후)";
  return new ReminderPopup(calendar,overdue,timing,title.isEmpty()?"내용을 확인해주세요.":title,date);
 }
}
