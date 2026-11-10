from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[2]
android=root/'guesthouse-manager-app/app/src/androidTest'
dest=android/'java/com/oneminute/guesthousemanager'
(dest/'LargeVideoProbe.java').write_text((Path(__file__).parent/'LargeVideoProbe.java').read_text())
runner=dest/'UpdateProbe.java'
runner.write_text(runner.read_text().replace('  if("reminder-design"', '  if("large-video".equals(phase)){LargeVideoProbe.run(this);return;}\n  if("reminder-design"'))
assets=android/'assets';assets.mkdir(exist_ok=True)
video=assets/'large-video.mp4'
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=1920x1080:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','20','-c:v','libx264','-preset','ultrafast','-b:v','24M','-minrate','24M','-maxrate','24M','-bufsize','24M','-x264-params','nal-hrd=cbr:force-cfr=1','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-movflags','+faststart','-y',str(video)],check=True)
assert 55000000<=video.stat().st_size<=65000000,video.stat().st_size
print('Generated real H.264/AAC source bytes:',video.stat().st_size)
