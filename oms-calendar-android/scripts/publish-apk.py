import os,sys,json,subprocess,re,hashlib,shutil
from pathlib import Path
from datetime import datetime,timezone
apk=Path(sys.argv[1]);tools=Path(os.environ['ANDROID_HOME'])/'build-tools';versions=sorted(tools.iterdir(),key=lambda p:[int(x) for x in re.findall(r'\d+',p.name)]);tool=versions[-1]
verification=subprocess.run([str(tool/'apksigner'),'verify','--print-certs',str(apk)],capture_output=True,text=True,check=True)
output=verification.stdout+'\n'+verification.stderr
certificates={value.lower() for value in re.findall(r'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})',output)}
expected=os.environ['OMS_CERTIFICATE_SHA256'].lower()
if certificates!={expected}:raise SystemExit('Unexpected or missing signing certificate: '+output)
fp=expected
badging=subprocess.check_output([str(tool/'aapt'),'dump','badging',str(apk)],text=True)
package,code,name=re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'",badging).groups()
if package!='com.omgworks.calendar' or int(code)<1:raise SystemExit('Unexpected APK identity or version')
if not re.fullmatch(r'\d+(?:\.\d+){2}',name):raise SystemExit('Unsafe APK version name')
root=Path('downloads');root.mkdir(exist_ok=True);metadata=root/'oms-calendar-update.json';old=json.loads(metadata.read_text()) if metadata.exists() else None
if old and (old['certificate_sha256']!=fp or int(code)<old['version_code']):raise SystemExit('Update compatibility check failed')
shutil.copy2(apk,root/'OMS-Calendar-latest.apk')
filename=f'OMS-Calendar-{name}.apk'
shutil.copy2(apk,root/filename)
shutil.copy2(apk,apk.with_name(filename))
info={'version_code':int(code),'version_name':name,'apk_url':'https://omgworks24.com/downloads/'+filename,'certificate_sha256':fp,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'published_at':datetime.now(timezone.utc).isoformat(),'bootstrap_required':old is None}
metadata.write_text(json.dumps(info,indent=2)+'\n')
print('Verified signed Calendar update:', code, name)
