/* Public website copy only; application screens keep their own language settings. */
(() => {
  "use strict";
  const english = {
  "직원 정보와 근태, 일정과 할 일, 청소 스케줄, 직원 소통까지 실제 숙소 운영을 돕는 OMS입니다.": "Manage staff, attendance, tasks, schedules, cleaning and team communication with OMS.",
  "OMS · 현장 운영을 손쉽게": "OMS · Everyday operations, made simple",
  "사업장 운영 통합관리 시스템": "All-in-one operations",
  "직원 출퇴근, 급여는 엑셀로": "Attendance & payroll in Excel",
  "엑셀": "Excel",
  "근로계약서는 종이로": "Employment contracts on paper",
  "할 일은 카카오톡": "Tasks via KakaoTalk",
  ", 전화로": " or phone",
  "시키고": "",
  "일정은 구글 캘린더": "Schedules in Google Calendar",
  "로 관리하세요?": "?",
  "OMS 하나로 편하게 관리하세요": "Run it all with OMS",
  "근태, 급여, 할 일, 일정, 소통까지 한곳에서": "Attendance, payroll, tasks and team chat. All together.",
  "OMS 접속하기": "Log in to OMS",
  "가입하기": "Sign up",
  "OMS 주요 기능": "OMS features",
  "직원 정보·근태 관리": "Staff & attendance",
  "인적사항 · 급여 계산 · 휴일 · 근로계약서": "Staff profiles, payroll, leave and contracts.",
  "지각 경고와 횟수까지 체계적으로": "Keep track of lateness, too.",
  "자세히 보기": "Explore",
  "직원 정보를 확인하는 근무자": "Team member checking staff information",
  "일정·할 일 관리": "Schedules & tasks",
  "누가, 무엇을, 언제까지 해야 하는지": "Assign owners and deadlines.",
  "완료까지 추적하고 강력한 리마인더로 관리합니다": "Follow through with reminders.",
  "할 일 목록을 확인하는 근무자": "Team member checking a task list",
  "청소 스케줄 관리": "Cleaning schedules",
  "객실별 청소 일정과 담당자,": "Room schedules, staff assignments",
  "진행 상태를 한눈에": "and progress at a glance.",
  "객실을 청소하는 근무자": "Team member cleaning a room",
  "직원 전용 메신저": "Team messenger",
  "업무 대화와 공지,": "Work chats, announcements",
  "사진 공유를 한곳에서": "and photos in one place.",
  "직원 메신저를 사용하는 근무자": "Team member using the staff messenger",
  "운영의 마지막 한 조각,": "The missing piece:",
  "숙소관리": "Property",
  "채널관리": "Channels",
  "PMS와 CMS로 채운 원. 현장관리의 3분의 1은 비어 있습니다.": "PMS and CMS fill two thirds of the circle. On-site operations are the missing third.",
  "현장관리": "Operations",
  "PMS, CMS, OMS가 각각 3분의 1을 채워 완성된 원": "PMS, CMS and OMS each fill one third to complete the circle.",
  "를 더하면, 운영이 완성됩니다.": " completes your operations.",
  "OMS 안드로이드 앱 설치 ·": "Get OMS for Android ·",
  "자동 출퇴근 기록, 근무시간·지각 횟수·급여 확인부터 근로계약서 진행 현황과 전자서명·PDF 보관까지 OMS에서 관리하세요.": "Track attendance, hours and payroll. Manage employment contracts, electronic signatures and signed PDFs with OMS.",
  "근태·급여 · OMS": "Attendance & payroll · OMS",
  "OMS 홈": "OMS home",
  "← 전체 기능": "← All features",
  "다른 기능 살펴보기": "Explore other features",
  "근태·급여": "Staff & payroll",
  "일정·할 일": "Schedules & tasks",
  "사진 보고": "Photo reports",
  "메신저": "Messenger",
  "기록은 자동으로.": "Hours, recorded.",
  "급여는 한눈에.": "Payroll, at a glance.",
  "별도의 출퇴근 기입 없이 급여 자동 계산.": "Calculate pay from attendance records.",
  "근무시간과 지각 횟수까지 한눈에 확인하세요.": "See working hours and lateness in one place.",
  "출퇴근 보고 → 기록 저장 → 근무시간·급여": "Clock in & out → Save records → Calculate pay",
  "오른쪽 화면에서 기능을 살펴보세요": "Explore the interactive previews",
  "근태관리": "Attendance",
  "월요일": "Monday",
  "전체 근무자⌄": "All staff⌄",
  "총 근무시간": "Total hours",
  "시간": "h",
  "근무일수": "Days worked",
  "일": "d",
  "지각 횟수": "Late arrivals",
  "회": "times",
  "미기록": "Missing logs",
  "건": "items",
  "출퇴근 기록표": "Attendance log",
  "엑셀로 보관": "Export to Excel",
  "근무자": "Staff",
  "출근": "Clock in",
  "퇴근": "Clock out",
  "근무시간": "Hours",
  "상태": "Status",
  "김민지": "Minji Kim",
  "본점": "Main branch",
  "8시간": "8 h",
  "완료": "Done",
  "이준호": "Junho Lee",
  "지각": "Late",
  "박서연": "Seoyeon Park",
  "출퇴근 기록 저장 → 근무시간 자동 집계": "Saved attendance → Hours calculated automatically",
  "실제 기능을 바탕으로 재구성한 예시 화면 · 예시 데이터": "Illustrative preview based on OMS features · Sample data",
  "급여 화면": "Payroll preview",
  "OMS / 급여정보": "OMS / Payroll",
  "급여정보": "Payroll",
  "2026년 10월⌄": "October 2026⌄",
  "기록된 근무시간을 급여 현황으로": "Turn recorded hours into a payroll overview",
  "급여현황": "Payroll overview",
  "월간 · 예시": "Monthly · Sample",
  "이름": "Name",
  "근무일": "Days",
  "총 급여": "Gross pay",
  "10일": "10 days",
  "80시간": "80 h",
  "960,000원": "₩960,000",
  "8일": "8 days",
  "64시간": "64 h",
  "768,000원": "₩768,000",
  "6일": "6 days",
  "48시간": "48 h",
  "576,000원": "₩576,000",
  "시급 12,000원 예시 · 세전 기본급 예상액 · 수당·공제 제외": "Example: ₩12,000/hour · Estimated base pay before tax, allowances and deductions",
  "근로계약서": "Employment contract",
  "전자서명으로 편리하게 관리하세요.": "Make signing simple.",
  "작성부터 전송·서명·완료까지, 진행 현황을 보고 서명한 계약서는 PDF로 보관하세요.": "Track each step from drafting to signing, and keep signed contracts as PDFs.",
  "OMS / 근로계약서 관리": "OMS / Contracts",
  "OOO · 근무자": "OOO · Staff",
  "관련문서": "Documents",
  "근로계약서 관리": "Contracts",
  "전송완료": "Sent",
  "계약서 작성": "Draft",
  "전송": "Send",
  "근로자 서명": "Staff signature",
  "근로자 서명을 기다리고 있어요": "Awaiting staff signature",
  "근무자가 내용을 확인하고 서명하면 PDF로 보관됩니다.": "The signed contract is saved as a PDF after staff review and sign it.",
  "전송한 계약서 보기": "View sent contract",
  "계약서 전체 내역·양식 관리 ›": "Contract history & templates ›",
  "문서보관함": "Document library",
  "＋ 문서 추가": "＋ Add document",
  "근로계약서 📄": "Employment contract 📄",
  "2026. 10. 1. · 서명 완료본": "Oct 1, 2026 · Signed copy",
  "OMS 앱의 관련문서 화면 · 예시 데이터": "OMS document screen · Sample data",
  "OMS / 근로자 전자서명": "OMS / Electronic signature",
  "표준 근로계약서": "Standard employment contract",
  "OOO(이하 “사업주”라 함)와 OOO(이하 “근로자”라 함)는 다음과 같이 근로계약을 체결한다.": "OOO (the employer) and OOO (the employee) enter into this employment agreement.",
  "계약서 본문 생략": "Contract body omitted",
  "손가락 또는 마우스로 서명": "Sign with your finger or mouse",
  "서명 지우기": "Clear signature",
  "계약 내용 전체를 확인했고, 본인이 전자서명하며 완료된 PDF를 내 문서함으로 교부받는 데 동의합니다.": "I have reviewed the contract and agree to sign electronically and receive the completed PDF in my document library.",
  "서명 완료": "Complete signature",
  "✓ 서명 완료 · PDF 문서함 보관 예시": "✓ Signed · PDF saved to the library (demo)",
  "OMS 앱의 계약서·서명 화면 · 본문 일부 생략 · 예시 데이터": "OMS contract and signature screens · Abridged · Sample data",
  "근무시간과 지각 횟수까지": "Hours and late arrivals",
  "출퇴근 기록을 저장하고 근태 현황을 함께 확인하세요.": "Keep attendance records and review staff attendance together.",
  "필요할 땐 엑셀로": "Export when you need it",
  "기간·근무자별 출퇴근 내역을 내려받으세요.": "Download attendance records by date and staff member.",
  "진행 현황부터 전자서명까지": "From draft to signature",
  "작성·전송·서명을 관리하고 완료 계약서는 PDF로 보관하세요.": "Manage drafting, delivery and signing, then keep the completed PDF.",
  "운영의 흐름을 한곳에서.": "Your operations, all together.",
  "일은 시키고 끝이 아닙니다. 담당자에게 진행 현황을 묻는 리마인더로 중간 확인과 최종 확인까지 관리하세요.": "Go beyond assigning tasks. Use reminders to check progress and follow through to completion.",
  "일정·할 일 · OMS": "Schedules & tasks · OMS",
  "일은 시키고": "Assign the task.",
  "끝이 아닙니다.": "Then follow through.",
  "중간 확인, 최종 확인까지.": "Check in. See it done.",
  "담당자에게 진행 현황을 묻는 지속적인 리마인더.": "Keep work moving with progress reminders.",
  "중간 확인과 최종 확인까지가 업무의 끝입니다.": "Follow each task through to the final result.",
  "업무 지정 → 중간 확인 → 최종 확인": "Assign → Check progress → Confirm completion",
  "리마인더": "Reminders",
  "업무 리마인더": "Task reminders",
  "알림 조건 설정 가능": "Custom timing",
  "담당자 · 이준호": "Assigned to Junho Lee",
  "소화기 점검": "Check extinguishers",
  "업무 진행 상태와 완료 내용을 확인해주세요.": "Review progress and confirm the result.",
  "3일 전 · 09:00": "3 days before · 09:00",
  "중간 확인": "Progress check",
  "맡은 업무의 진행 현황을 확인해주세요.": "Check the progress of your assigned task.",
  "1일 전 · 09:00": "1 day before · 09:00",
  "다시 리마인드": "Follow-up reminder",
  "마감 전에 진행 상황을 다시 살펴보세요.": "Review progress again before the deadline.",
  "마감 당일 · 14:00": "Due date · 14:00",
  "최종 확인": "Final check",
  "담당자에게 완료를 알리고 결과를 확인하세요.": "Report completion and review the result.",
  "알림 대상": "Notify",
  "☑ 대상근로자　☑ 관리자": "☑ Assigned staff　☑ Manager",
  "날짜·시각을 여러 조건으로 설정하는 리마인더 예시": "Example reminders with multiple dates and times",
  "기능별 화면": "Feature previews",
  "OMS / 일정·할 일": "OMS / Schedules & tasks",
  "2026년 10월": "October 2026",
  "월": "Month",
  "주": "Week",
  "화": "Tue",
  "수": "Wed",
  "목": "Thu",
  "금": "Fri",
  "토": "Sat",
  "객실 점검": "Rooms",
  "소모품 입고": "Supplies",
  "시설 점검": "Facilities",
  "오늘 + 지연": "Today + overdue",
  "지연 · 어제 마감": "Overdue · Due yesterday",
  "전 직원 안전 안내 확인": "Read the safety notice",
  "전체 직원 (모두 완료)": "All staff must complete",
  "택배 수령 후 창고 정리": "Unpack and store deliveries",
  "전체 직원 (누구든 1명 완료)": "Any one staff member can complete",
  "대기": "Pending",
  "오늘 할 일과 놓친 업무를 함께 확인": "See today's tasks and overdue work together",
  "OMS / 완료 방식": "OMS / Completion rules",
  "완료 방식": "Completion rules",
  "진행 현황": "Progress",
  "전체 직원": "All staff",
  "누구든 1명 완료": "Any one person",
  "소모품 택배를 확인하고 창고 선반에 정리해 주세요.": "Check the delivered supplies and put them on the storage shelves.",
  "완료 담당 예시": "Completed by (demo)",
  "오늘 14:00 마감": "Due today, 14:00",
  "예시로 완료해 보기": "Try completing this task",
  "✓ 업무 완료": "✓ Task complete",
  "김민지 · 택배 3박스 정리했습니다.": "Minji Kim · Unpacked and stored three boxes.",
  "한 명이 완료하면 전체 직원의 해당 업무가 완료됩니다.": "When one person finishes, the task is marked complete for everyone.",
  "지속적인 중간 확인": "Keep checking in",
  "여러 알림 조건으로 담당자에게 업무를 다시 알려주세요.": "Set multiple reminders to keep assigned staff on track.",
  "업무에 맞는 완료 방식": "Choose how work is completed",
  "전원 완료 또는 누구든 한 명 완료를 선택하세요.": "Require everyone to finish, or let any one person complete it.",
  "결과까지 보는 최종 확인": "See the final result",
  "완료자·작업 메모·사진으로 마지막 결과를 확인하세요.": "Review who finished the task, along with notes and photos.",
  "정해진 사진 업로드를 필수로 설정하고, 사진이 없으면 보고 제출을 막아 깜빡하는 일을 사전에 방지하세요.": "Make selected photos mandatory and prevent reports from being submitted without them.",
  "사진 보고 · OMS": "Photo reports · OMS",
  "사진, 빠뜨리기 전에.": "No missing photos.",
  "필수 보고로 막으세요.": "Make them required.",
  "정해진 사진 업로드를 필수로 설정하세요.": "Choose which photos every report needs.",
  "깜빡하고 사진을 안 찍는 일을 사전에 방지합니다.": "Catch missing photos before a report is submitted.",
  "필수 사진 설정 → 누락 시 제출 차단 → 사진 보고": "Require photos → Check uploads → Submit report",
  "업무 보고": "Work report",
  "사진 첨부 완료": "Photo attached",
  "본점 · 10월 12일 13:42": "Main branch · Oct 12, 13:42",
  "청소한 객실": "Rooms cleaned",
  "3건": "3 rooms",
  "침구 정리 사진": "Bed setup photo",
  "업로드 필수 설정": "Required upload",
  "필수": "Required",
  "침구 정리 사진을 추가해주세요.": "Please add a photo of the bed setup.",
  "정해진 사진이 없으면 보고를 제출할 수 없습니다.": "Upload the required photo before submitting.",
  "객실 보고 예시 사진 크게 보기": "Open the sample room photo",
  "정리된 침구와 수건이 놓인 객실의 예시 사진": "Sample room with freshly arranged bedding and towels",
  "청소 사진": "Cleaning photo",
  "↗ 크게 보기": "↗ Enlarge",
  "작업 메모": "Work notes",
  "침구 교체와 수건 비치를 완료했습니다.": "Changed the bedding and restocked towels.",
  "✓ 필수 사진 확인 · 보고 제출 가능": "✓ Required photo added · Ready to submit",
  "사진 누락 예시 보기": "Try missing photo",
  "예시로 보고 제출": "Submit demo report",
  "보고 사진 · 예시": "Report photo · Demo",
  "사진 확대": "Zoom in on photo",
  "확대 +": "Zoom in +",
  "사진 닫기": "Close photo",
  "닫기 ×": "Close ×",
  "객실 청소 보고 예시 사진 확대": "Enlarged sample room cleaning photo",
  "실제 기능을 바탕으로 재구성한 예시 화면 · 예시 데이터· 이미지": "Illustrative preview · Sample data and image",
  "객실번호와 함께": "Organize by room",
  "청소한 객실을 선택해 보고 내용을 구분하세요.": "Select cleaned rooms to organize each report.",
  "사진 업로드 의무화": "Require photo uploads",
  "필요한 사진 항목을 필수로 설정해 누락을 막으세요.": "Make key photos mandatory so nothing is missed.",
  "빠뜨리기 전에 확인": "Check before submitting",
  "필수 사진을 첨부해야 보고를 제출할 수 있습니다.": "Reports can only be submitted with the required photos.",
  "긴급 버튼으로 근무자에게 전달하고 미확인 시 반복 알림. 공지의 확인·미확인 상태와 이해 확인·이름 서명까지 관리하세요.": "Send urgent messages with repeat alerts, track acknowledgements and collect staff sign-offs on announcements.",
  "메신저 · OMS": "Messenger · OMS",
  "근무자가 놓치지 않도록.": "Make sure it's seen.",
  "확인할 때까지.": "And acknowledged.",
  "긴급 버튼으로 빠르게 전달하고, 미확인 시 반복 알람.": "Send urgent messages with repeat alerts.",
  "공지의 확인·미확인 현황과 이름 서명까지 관리하세요.": "Track who has read and signed off on each announcement.",
  "긴급 발송 → 근무자 수신 → 명시적 확인": "Send urgently → Staff receive → Acknowledge",
  "긴급 메시지": "Urgent messages",
  "본점 · 근무 중": "Main branch · On duty",
  "메시지 발송 화면 · 예시": "Sending a message · Demo",
  "! 긴급": "! Urgent",
  "문밖에 게스트가 와서 기다리고 있습니다.": "A guest is waiting outside.",
  "가서 바로 안내해주세요.": "Please go and help them now.",
  "긴급 메시지 · 발송 예시": "Urgent message · Demo",
  "수신 근무자에게 긴급 알림": "Urgent alert to staff",
  "긴급 발송 예시": "Try urgent send",
  "근무자에게 뜨는 알림 화면": "What staff see",
  "사장님 긴급 메시지": "Urgent manager message",
  "미확인": "Unconfirmed",
  "60초 미확인 시 반복 알람": "Repeat alert after 60 seconds",
  "확인할 때까지 알람이 계속됩니다.": "Alerts repeat until acknowledged.",
  "확인했습니다 · 예시": "Acknowledge (demo)",
  "재난문자급 강한 알림": "High-priority alerts",
  "긴급 모드 설정 가능 · Android 앱 예시": "Urgent mode available · Android app demo",
  "알림 권한과 기기·연결 상태에 따라 수신 및 알림 동작이 달라질 수 있습니다.": "Delivery and alerts depend on notification permissions, your device and connectivity.",
  "OMS / 공지 확인": "OMS / Acknowledgements",
  "공지 확인": "Acknowledgements",
  "공지": "Announcement",
  "야간 출입문 잠금 확인": "Check the doors at night",
  "마지막 근무자는 퇴근 전": "The last person on duty should",
  "출입문 잠금 상태를 확인해 주세요.": "check that the doors are locked before leaving.",
  "공지 내용을 이해했습니다.": "I understand this announcement.",
  "확인자 이름 · 성명 서명": "Acknowledged by · Full name",
  "이름 입력 확인": "Name confirmed",
  "공지 확인 내역": "Acknowledgement log",
  "/ 3명 확인": "/ 3 confirmed",
  "확인·서명 완료": "Signed off",
  "확인·미확인 현황과 이해 확인·이름 입력 내역을 함께 확인": "Track acknowledgements, understanding and named sign-offs",
  "긴급 버튼으로 확실하게": "Urgent when it matters",
  "수신 후 60초 미확인 시, 명시적으로 확인할 때까지 반복 알람.": "If unconfirmed after 60 seconds, alerts repeat until acknowledged.",
  "확인·미확인이 보이는 공지": "Know who's read it",
  "누가 확인했고 누가 아직 확인하지 않았는지 살펴보세요.": "See who has acknowledged each announcement and who has not.",
  "필수 내용은 이름 서명까지": "Get a named sign-off",
  "공지의 이해 확인과 본인 이름 입력 내역을 남기세요.": "Keep a record of understanding and each person's named sign-off.",
  "축소 −": "Zoom out −",
  "사진 축소": "Zoom out of photo",
  "! 필수 사진이 없습니다. 사진을 첨부해야 제출할 수 있습니다.": "! Required photo missing. Add it before submitting.",
  "사진 누락": "Photo missing",
  "사진 첨부 예시 복원": "Restore sample photo",
  "✓ 필수 사진과 함께 보고가 완료되었습니다. · 예시": "✓ Report submitted with the required photo (demo)",
  "보고 완료": "Report submitted",
  "계약 내용을 확인해주세요.": "Please review and accept the contract.",
  "서명을 입력해주세요.": "Please add your signature.",
  "근무자 수신 예시 · 확인 대기": "Delivered to staff · Awaiting acknowledgement (demo)",
  "확인 완료": "Acknowledged",
  "이준호 · 확인 완료 예시": "Junho Lee · Acknowledged (demo)",
  "명시적 확인 → 알림 종료": "Acknowledged → Alerts stop",
  "확인 여부까지 화면에서 살펴보세요.": "See the acknowledgement status here.",
  "확인 완료 · 알림 종료 예시": "Acknowledged · Alerts stopped (demo)",
  "언어 선택": "Select language"
};
  const KEY='oms.public.language', pages=new Set(['index.html','feature-staff.html','feature-tasks.html','feature-cleaning.html','feature-messenger.html']);
  let language='ko';
  try { language=new URL(location.href).searchParams.get('lang')||localStorage.getItem(KEY)||'ko'; } catch (_) {}
  if(!['ko','en'].includes(language))language='ko';
  document.documentElement.lang=language;
  const texts=new WeakMap(), attributes=new WeakMap();
  const skip=element=>!element||element.closest('script,style,noscript,[data-site-language]');
  function translated(original,override){
    const key=original.trim();
    if(language!=='en')return original;
    const value=override??english[key];
    return value===undefined?original:original.replace(key,value);
  }
  function text(node){
    if(skip(node.parentElement))return;
    let saved=texts.get(node);
    if(!saved||saved.rendered!==node.nodeValue)saved={original:node.nodeValue};
    const value=translated(saved.original,node.parentElement.getAttribute('data-site-en')??undefined);
    if(node.nodeValue!==value)node.nodeValue=value;
    saved.rendered=value;texts.set(node,saved);
  }
  function element(el){
    if(skip(el))return;
    const saved=attributes.get(el)||{};
    for(const name of ['aria-label','alt','title',...(el.matches('meta[name="description"]')?['content']:[])]){
      if(!el.hasAttribute(name))continue;
      const current=el.getAttribute(name);
      if(!saved[name]||saved[name].rendered!==current)saved[name]={original:current};
      const value=translated(saved[name].original);
      if(current!==value)el.setAttribute(name,value);
      saved[name].rendered=value;
    }
    attributes.set(el,saved);
    if(el.matches('a[href]')){
      const url=new URL(el.href,location.href),file=url.pathname.split('/').pop()||'index.html';
      if(url.origin===location.origin&&pages.has(file)){
        if(language==='en')url.searchParams.set('lang','en');else url.searchParams.delete('lang');
        if(el.href!==url.href)el.href=url.href;
      }
    }
  }
  function translate(root){
    if(root.nodeType===Node.TEXT_NODE){text(root);return;}
    if(root.nodeType!==Node.ELEMENT_NODE&&root.nodeType!==Node.DOCUMENT_NODE)return;
    if(root.nodeType===Node.ELEMENT_NODE){if(skip(root))return;element(root);}
    const walker=document.createTreeWalker(root,NodeFilter.SHOW_ELEMENT|NodeFilter.SHOW_TEXT);
    while(walker.nextNode()){const node=walker.currentNode;if(node.nodeType===Node.TEXT_NODE)text(node);else element(node);}
  }
  function select(value,persist=true){
    language=value==='en'?'en':'ko';document.documentElement.lang=language;
    if(persist){
      try{localStorage.setItem(KEY,language);}catch(_){}
      try{const url=new URL(location.href);if(language==='en')url.searchParams.set('lang','en');else url.searchParams.delete('lang');history.replaceState(history.state,'',url);}catch(_){}
    }
    document.querySelectorAll('[data-site-language]').forEach(node=>{node.value=language;node.setAttribute('aria-label',language==='en'?'Select language':'언어 선택');});
    translate(document);
  }
  // Translate text changes from the interactive demos without rebuilding controls or losing their state.
  new MutationObserver(records=>{
    for(const record of records){
      if(record.type==='childList')record.addedNodes.forEach(translate);
      else if(record.type==='characterData')text(record.target);
      else element(record.target);
    }
  }).observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['aria-label','alt','title','content']});
  document.addEventListener('change',event=>{if(event.target.matches('[data-site-language]'))select(event.target.value);});
  document.addEventListener('DOMContentLoaded',()=>select(language,false));
  addEventListener('storage',event=>{if(event.key===KEY)select(event.newValue,false);});
})();
