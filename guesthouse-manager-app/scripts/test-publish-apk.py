import tempfile,pathlib,subprocess,os,json,hashlib
script=pathlib.Path(__file__).with_name('publish-apk.py').resolve()
fingerprint='1'*64
cases=[
 ('numbered signer',f'Signer #1 certificate SHA-256 digest: {fingerprint}',True),
 ('SDK signer range',f'Signer (minSdkVersion=24, maxSdkVersion=2147483647) certificate SHA-256 digest: {fingerprint}',True),
 ('wrong certificate','Signer #1 certificate SHA-256 digest: '+'2'*64,False),
 ('missing certificate','Verifies',False),
]
for label,output,accepted in cases:
 with tempfile.TemporaryDirectory() as directory:
  root=pathlib.Path(directory);sdk=root/'sdk'/'build-tools'/'35.0.0';sdk.mkdir(parents=True)
  for name,body in [('apksigner',output),('aapt',"package: name='com.oneminute.guesthousemanager' versionCode='1115' versionName='0.15.0'")]:
   executable=sdk/name;executable.write_text('#!/usr/bin/env python3\nprint('+repr(body)+')\n');executable.chmod(0o755)
  apk=root/'app.apk';apk.write_bytes(b'public-test-apk')
  (root/'index.html').write_text('<a data-apk-download href="downloads/OMS-latest.apk">Install <span data-apk-version>old</span></a>')
  env=dict(os.environ,ANDROID_HOME=str(root/'sdk'),OMS_CERTIFICATE_SHA256=fingerprint,OMS_VERSION_CODE='1115')
  result=subprocess.run(['python3',str(script),str(apk)],cwd=root,env=env,capture_output=True,text=True)
  assert (result.returncode==0)==accepted,(label,result.stderr)
  assert (root/'downloads'/'oms-update.json').exists()==accepted,label
  if accepted:
   info=json.loads((root/'downloads'/'oms-update.json').read_text())
   assert info['apk_url'].endswith('/OMS-0.15.0.apk'),label
   for file in ['OMS-0.15.0.apk','OMS-latest.apk']:assert hashlib.sha256((root/'downloads'/file).read_bytes()).hexdigest()==info['sha256'],label
   home=(root/'index.html').read_text();assert 'href="downloads/OMS-0.15.0.apk"' in home and 'download="OMS-0.15.0.apk"' in home and '>0.15.0</span>' in home,label
  print('PASS',label)
