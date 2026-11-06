package com.oneminute.guesthousemanager;
import org.junit.Test;
import org.json.JSONObject;
import static org.junit.Assert.*;
public class MessagePopupQueueTest {
 private JSONObject item(String id)throws Exception{return new JSONObject().put("alertId",id).put("message",id);}
 @Test public void fourAlertsStayInOrderAndSurviveRestarts()throws Exception{
  MessagePopupQueue q=new MessagePopupQueue("{}");
  for(int i=1;i<=4;i++)assertTrue(q.offer(item("m"+i)));
  assertFalse(q.offer(item("m1")));assertEquals(4,q.size());
  q=new MessagePopupQueue(q.save());assertEquals("m1",q.peek().getString("message"));
  assertFalse(q.confirm("m4"));assertEquals(4,q.size());
  for(int i=1;i<=4;i++){assertEquals("m"+i,q.peek().getString("alertId"));assertTrue(q.confirm("m"+i));assertFalse(q.offer(item("m"+i)));q=new MessagePopupQueue(q.save());}
  assertNull(q.peek());assertEquals(0,q.size());
 }
 @Test public void arrivalsWhileReadingDoNotReplaceHead()throws Exception{
  MessagePopupQueue q=new MessagePopupQueue("{}");q.offer(item("first"));q.offer(item("next"));
  assertEquals("first",q.peek().getString("alertId"));q.confirm("first");q.offer(item("later"));
  assertEquals("next",q.peek().getString("alertId"));assertEquals(2,q.size());
 }
}
