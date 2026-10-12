import tempfile,pathlib,subprocess,os
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
  env=dict(os.environ,ANDROID_HOME=str(root/'sdk'),OMS_CERTIFICATE_SHA256=fingerprint,OMS_VERSION_CODE='1115')
  result=subprocess.run(['python3',str(script),str(apk)],cwd=root,env=env,capture_output=True,text=True)
  assert (result.returncode==0)==accepted,(label,result.stderr)
  assert (root/'downloads'/'oms-update.json').exists()==accepted,label
  print('PASS',label)
