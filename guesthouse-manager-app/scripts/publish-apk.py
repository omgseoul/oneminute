import os,sys,json,subprocess,re,hashlib,shutil
from pathlib import Path
from datetime import datetime,timezone
apk=Path(sys.argv[1]);tools=Path(os.environ['ANDROID_HOME'])/'build-tools';versions=sorted(tools.iterdir(),key=lambda p:[int(x) for x in re.findall(r'\d+',p.name)]);tool=versions[-1]
output=subprocess.check_output([str(tool/'apksigner'),'verify','--print-certs',str(apk)],text=True)
fp=re.search(r'Signer #1 certificate SHA-256 digest: ([0-9a-f]+)',output).group(1)
if fp!=os.environ['OMS_CERTIFICATE_SHA256']:raise SystemExit('Unexpected signing certificate')
badging=subprocess.check_output([str(tool/'aapt'),'dump','badging',str(apk)],text=True)
package,code,name=re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'",badging).groups()
if package!='com.oneminute.guesthousemanager' or int(code)!=int(os.environ['OMS_VERSION_CODE']):raise SystemExit('Unexpected APK identity or version')
root=Path('downloads');root.mkdir(exist_ok=True);metadata=root/'oms-update.json';old=json.loads(metadata.read_text()) if metadata.exists() else None
if old and (old['certificate_sha256']!=fp or int(code)<old['version_code']):raise SystemExit('Update compatibility check failed')
shutil.copy2(apk,root/'OMS-latest.apk')
info={'version_code':int(code),'version_name':name,'apk_url':'https://omgworks24.com/downloads/OMS-latest.apk','certificate_sha256':fp,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'published_at':datetime.now(timezone.utc).isoformat(),'bootstrap_required':old is None}
metadata.write_text(json.dumps(info,indent=2)+'\n')
print('Verified release identity, persistent certificate and monotonic versionCode:',code)
