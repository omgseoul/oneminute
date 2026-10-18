"""Bundle real web navigation code into an offline debug-only Android test page."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
script = lambda name: '<script>' + (root / name).read_text().replace('</script', '<\\/script') + '</script>'
html = '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body>
<nav id="fixtureNav"><button data-hub="staff">직원 <span id="staffCount"></span></button></nav>
<div id="fixtureMarker">unchanged hub</div>
<section id="fixtureApproval"><div id="detailMeta"><span>승인 내역</span><small>오늘</small></div></section>
<script>
window.fixtureNonce=Math.random().toString();
window.GuestSupport={esc:s=>String(s??'')};
window.omgSupabase={rpc:async(name)=>({data:{ok:true,profile:{display_name:'김한울',job_title:'평일 오전',property_name:'One Minute'},rooms:[{peer:'employee:12345678-1234-4234-8234-123456789def',name:'근무자',preview:'확인',property_id:'home',updated_at:'2026-10-18T00:00:00Z'}]}})};
</script>'''
html += script('page-transition.js') + script('staff-chat-client.js') + script('message-profiles.js')
html += '''<script>
StaffConversations.init({propertyId:'home',accessToken:'fixture'},document.getElementById('fixtureNav'));
StaffConversations.show(true);
history.replaceState({omgMessageLayer:true},'',location.href);
MessageProfiles.bind({sender_employee_id:'12345678-1234-4234-8234-123456789def',sender_label:'김한울'},{accessToken:'fixture'});
window.fixtureReady=true;
</script></body></html>'''
destination = root / 'guesthouse-manager-app/app/src/debug/assets/chat-handoff.html'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(html)
print('Prepared offline WebView/native handoff fixture')
