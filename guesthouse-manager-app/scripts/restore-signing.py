import os,json,urllib.request,urllib.parse,base64,re
from pathlib import Path
req_url=os.environ['ACTIONS_ID_TOKEN_REQUEST_URL']+'&audience='+urllib.parse.quote('https://omgworks24.com/android-signing',safe='')
request=urllib.request.Request(req_url,headers={'Authorization':'Bearer '+os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
with urllib.request.urlopen(request,timeout=30) as r:token=json.load(r)['value']
print('::add-mask::'+token)
request=urllib.request.Request('https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/android-signing',data=b'{}',headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'},method='POST')
with urllib.request.urlopen(request,timeout=30) as r:material=json.load(r)
for key in ['store_base64','store_password']:
 if not isinstance(material.get(key),str) or '\n' in material[key]:raise ValueError('Invalid signing material')
 print('::add-mask::'+material[key])
if not re.fullmatch(r'[a-zA-Z0-9_-]+',material['key_alias']):raise ValueError('Invalid key alias')
if not re.fullmatch(r'[0-9a-f]{64}',material['certificate_sha256']):raise ValueError('Invalid certificate')
path=Path(os.environ['RUNNER_TEMP'])/'oms-release.p12';path.write_bytes(base64.b64decode(material['store_base64'],validate=True));path.chmod(0o600)
with open(os.environ['GITHUB_ENV'],'a') as f:
 for key,value in {'OMS_KEYSTORE_FILE':str(path),'OMS_STORE_PASSWORD':material['store_password'],'OMS_KEY_ALIAS':material['key_alias'],'OMS_CERTIFICATE_SHA256':material['certificate_sha256'],'OMS_VERSION_CODE':str(1000+int(os.environ['GITHUB_RUN_NUMBER']))}.items():f.write(key+'='+value+'\n')
print('Restored persistent OMS release certificate: '+material['certificate_sha256'])
