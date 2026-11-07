from pathlib import Path
import re,base64
root=Path(__file__).resolve().parents[2];dest=root/'guesthouse-manager-app/app/src/debug/assets/login-ime-fixture.html';dest.parent.mkdir(parents=True,exist_ok=True)
s=(root/'login.html').read_text()
keep={'page-transition.js','property-selector.js','select-picker.js','native-login-input.js'}
def inline(m):
 name=m[1].split('?')[0]
 return '<script>'+ (root/name).read_text()+'</script>' if name in keep else ''
s=re.sub(r'<script src="([^"]+)"></script>',inline,s)
s=s.replace('<link rel="stylesheet" href="page-transition.css">','<style>'+(root/'page-transition.css').read_text()+'</style>')
s=s.replace('src="oms-logo-signature.webp?v=20261010-login"','src="data:image/webp;base64,'+base64.b64encode((root/'oms-logo-signature.webp').read_bytes()).decode()+'"')
s=s.replace('<head>','<head><script>window.omgSession={get:()=>null};window.omgAccount={require:async()=>({user:{email:"ime.fixture"}})};window.omgSupabase={rpc:async(name,args)=>{if(name==="get_or_create_account_property")return{data:{ok:true}};if(name==="list_account_login_admins")return{data:[{owner_id:"fixture",display_name:"테스트 관리자"}]};window.testSubmittedLoginId=args.p_login_id;return{data:{ok:false,message:"테스트 제출 완료"}};}};</script>')
dest.write_text(s)
