package com.oneminute.guesthousemanager;
import org.junit.Test;
import org.json.*;
import static org.junit.Assert.*;

public class NativeStaffChatStateTest {
 @Test public void pagingDeduplicatesAndRefreshesExistingReceipts()throws Exception{
  NativeStaffChatState state=new NativeStaffChatState();
  state.merge(new JSONArray("[{id:'b',created_at:'2026-10-18T01:00:00Z',read_at:null},{id:'c',created_at:'2026-10-18T01:01:00Z',attachment_type:'video/mp4'}]"));
  state.merge(new JSONArray("[{id:'a',created_at:'2026-10-18T00:59:00Z'},{id:'b',created_at:'2026-10-18T01:00:00Z',read_at:'2026-10-18T01:01:00Z'}]"));
  assertEquals(3,state.messages.size());assertEquals("a",state.messages.get(0).getString("id"));assertFalse(state.messages.get(1).isNull("read_at"));assertEquals(1,state.media().size());
 }
 @Test public void retryReusesIdUntilTheUserChangesTheMessage(){
  String id=NativeStaffChatState.pendingId("old","new","");assertEquals(id,NativeStaffChatState.pendingId("new","new",id));assertNotEquals(id,NativeStaffChatState.pendingId("new","edited",id));
 }
 @Test public void contractLinkIsPreservedSeparatelyFromVisibleText(){String body="계약 확인\n[OMS-CONTRACT:12345678-1234-1234-1234-123456789012]";assertEquals("계약 확인",NativeStaffChatState.clean(body));assertEquals("12345678-1234-1234-1234-123456789012",NativeStaffChatState.contract(body));assertNull(NativeStaffChatState.contract("일반 대화"));}
}
