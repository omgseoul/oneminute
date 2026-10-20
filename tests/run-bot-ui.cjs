const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),{spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.webp':'image/webp','.png':'image/png'};
const server=http.createServer((req,res)=>{const name=path.resolve(root,'.'+new URL(req.url,'http://local').pathname);if(!name.startsWith(root+path.sep)||!fs.existsSync(name)){res.writeHead(404);return res.end();}res.setHeader('content-type',mime[path.extname(name)]||'application/octet-stream');res.end(fs.readFileSync(name));});
server.listen(0,'127.0.0.1',()=>{const child=spawn(process.execPath,[path.join(__dirname,'notification-bot-ui.cjs')],{cwd:root,env:{...process.env,BOT_TEST_URL:'http://127.0.0.1:'+server.address().port+'/'},stdio:'inherit'});child.on('exit',code=>{server.close();process.exitCode=code||0});child.on('error',e=>{console.error(e);server.close();process.exitCode=1});});
