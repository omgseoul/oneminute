package com.oneminute.guesthousemanager;
import org.junit.Test;
import static org.junit.Assert.*;
import java.time.Instant;
public class ReminderPopupTest {
 @Test public void overdueHasOneHeader(){ReminderPopup r=ReminderPopup.parse("To do 알림\n2일 지연: 냉장고 정리","OMS 도우미");assertEquals("지연된 업무",r.heading);assertEquals("(2일 지연)",r.timing);assertEquals("냉장고 정리",r.title);assertTrue(r.overdue);}
 @Test public void dateUpdatesInPropertyTimezone(){Instant now=Instant.parse("2026-11-07T00:00:00Z");ReminderPopup r=ReminderPopup.parse("일정 알림\n등록: 회의\n일정: 2026-11-07 14:00\n시간대: Asia/Seoul","OMS",now);assertEquals("(오늘)",r.timing);r=ReminderPopup.parse("To do 알림\n내일: 청소\n마감: 2026-11-06 14:00\n시간대: Asia/Seoul","OMS",now);assertEquals("(1일 지연)",r.timing);r=ReminderPopup.parse("To do 알림\n오늘: 청소\n마감: 2026-11-07 14:00\n시간대: America/New_York","OMS",now);assertEquals("(1일 후)",r.timing);}
 @Test public void legacyAndOrdinary(){assertNull(ReminderPopup.parse("안녕하세요","직원"));assertEquals("",ReminderPopup.parse("To do 알림\\n지연: 예전 업무","OMS").timing);assertEquals("(오늘)",ReminderPopup.parse("오늘: 청소","To do 알림").timing);}
}
