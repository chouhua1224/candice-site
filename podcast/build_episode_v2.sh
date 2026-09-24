#!/bin/bash
# 用法: ./build_episode_v2.sh <EP編號> <稿件路徑> <節目標題>
# v2 改進：逐「停頓單元」轉檔、語速 -8%、單元/段落/章節之間插入靜音
set -e
EP=$1; SCRIPT=$2; TITLE=$3
BASE="/Users/candice/Documents/Candice_Claude/candice-site/podcast"
DIR="$BASE/ep$EP"
EDGE=/Users/candice/Library/Python/3.9/bin/edge-tts
mkdir -p "$DIR"; cd "$DIR"
rm -f unit_*.mp3 u_*.txt

# 靜音素材（與語音同規格：24kHz 單聲道 48kbps）
mkfifo_sil() { ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=24000:cl=mono -t $1 -c:a libmp3lame -b:a 48k $2; }
mkfifo_sil 0.60 sil_unit.mp3    # 停頓單元之間
mkfifo_sil 1.20 sil_para.mp3    # 段落之間
mkfifo_sil 1.60 sil_chap.mp3    # 章節之間

# 1. 切章 → 切停頓單元
python3 - "$SCRIPT" <<'PYEOF'
import re,sys,json
txt=open(sys.argv[1],encoding='utf-8').read()
parts=re.split(r'===CHAPTER:\s*(.+?)===\n', txt)
chapters=[(parts[i].strip(),parts[i+1].strip()) for i in range(1,len(parts),2)]

MAX=90   # 每個停頓單元的目標字數
plan=[]  # [(章index, 段index, 單元文字)]
for ci,(title,body) in enumerate(chapters):
    paras=[p.strip() for p in body.split('\n') if p.strip()]
    for pi,para in enumerate(paras):
        # 依句末標點切句，再合併成 ~MAX 字的單元
        sents=re.findall(r'[^。！？]*[。！？]|[^。！？]+$', para)
        sents=[s for s in sents if s.strip()]
        buf=''
        for s in sents:
            if buf and len(buf)+len(s)>MAX:
                plan.append((ci,pi,buf)); buf=s
            else:
                buf+=s
        if buf: plan.append((ci,pi,buf))

for i,(ci,pi,t) in enumerate(plan):
    open(f'u_{i:04d}.txt','w',encoding='utf-8').write(t)
json.dump({'titles':[t for t,_ in chapters],
           'plan':[[ci,pi] for ci,pi,_ in plan]},
          open('plan.json','w'),ensure_ascii=False)
print(f'{len(chapters)} 章 → {len(plan)} 個停頓單元，共 {sum(len(t) for _,_,t in plan)} 字')
PYEOF

# 2. 逐單元轉檔（語速 -8%）
N=$(ls u_*.txt | wc -l | tr -d ' ')
i=0
for f in u_*.txt; do
  u="${f%.txt}"
  $EDGE --voice zh-TW-YunJheNeural --rate=-8% -f "$f" --write-media "unit_${u#u_}.mp3" 2>/dev/null
  i=$((i+1))
  [ $((i % 20)) -eq 0 ] && echo "  轉檔進度 $i/$N"
done
echo "  轉檔完成 $N/$N"

# 3. 組裝：單元間 0.6s、段落間 1.2s、章節間 1.6s；同時算章節起點
python3 - "$TITLE" <<'PYEOF'
import json,subprocess,sys,os
title=sys.argv[1]
d=json.load(open('plan.json'))
titles=d['titles']; plan=d['plan']
dur=lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration',
  '-of','default=noprint_wrappers=1:nokey=1',f],capture_output=True,text=True).stdout.strip())
SIL={'unit':dur('sil_unit.mp3'),'para':dur('sil_para.mp3'),'chap':dur('sil_chap.mp3')}

seq=[]; t=0.0; starts={}
prev=None
for i,(ci,pi) in enumerate(plan):
    if prev is not None:
        if ci!=prev[0]:   gap='chap'
        elif pi!=prev[1]: gap='para'
        else:             gap='unit'
        seq.append(f'sil_{gap}.mp3'); t+=SIL[gap]
    if ci not in starts: starts[ci]=t
    f=f'unit_{i:04d}.mp3'
    seq.append(f); t+=dur(f)
    prev=(ci,pi)

open('concat.txt','w').write('\n'.join(f"file '{x}'" for x in seq))
meta=[';FFMETADATA1',f'title={title}','artist=Candice 的頻道']
lines=[]
for ci,ct in enumerate(titles):
    s=starts[ci]; e=starts[ci+1] if ci+1 in starts else t
    meta+=['','[CHAPTER]','TIMEBASE=1/1000',f'START={int(s*1000)}',f'END={int(e*1000)}',f'title={ct}']
    lines.append(f'{int(s//60):02d}:{int(s%60):02d} {ct}')
open('chapters.txt','w',encoding='utf-8').write('\n'.join(meta))
open('timestamps.txt','w',encoding='utf-8').write('\n'.join(lines))
chars=sum(len(open(f'u_{i:04d}.txt',encoding='utf-8').read()) for i in range(len(plan)))
print(f'\n總長 {int(t//60)}分{int(t%60)}秒　語速 {chars/t:.2f} 字/秒（含停頓）')
print('\n'.join(lines))
PYEOF

# 4. 合併（重新編碼確保時間戳精準）
export JOINED=/tmp/ep$EP.mp3
ffmpeg -y -loglevel error -f concat -safe 0 -i concat.txt -c:a libmp3lame -b:a 48k -ar 24000 -ac 1 /tmp/ep$EP.mp3

# 4b. 校正合併造成的累積誤差（mp3 frame padding，約 0.3%），否則後段章節會偏掉
python3 - <<'FIXEOF'
import subprocess,re
d=lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration',
  '-of','default=noprint_wrappers=1:nokey=1',f],capture_output=True,text=True).stdout.strip())
import os
actual=d(os.environ.get('JOINED','/tmp/ep.mp3'))
meta=open('chapters.txt',encoding='utf-8').read()
computed=max(int(x) for x in re.findall(r'END=(\d+)',meta))/1000
scale=actual/computed
meta=re.sub(r'(START|END)=(\d+)', lambda m: f'{m.group(1)}={int(int(m.group(2))*scale)}', meta)
open('chapters.txt','w',encoding='utf-8').write(meta)
starts=[int(x) for x in re.findall(r'START=(\d+)',meta)]
titles=re.findall(r'title=(.+)',meta)[1:]
open('timestamps.txt','w',encoding='utf-8').write(
  '\n'.join(f'{s//60000:02d}:{s//1000%60:02d} {t}' for s,t in zip(starts,titles)))
print(f'  章節校正：{computed:.1f}s → {actual:.1f}s（係數 {scale:.5f}）')
FIXEOF

# 必須用 -map_chapters 才會覆蓋既有章節
ffmpeg -y -loglevel error -i /tmp/ep$EP.mp3 -i chapters.txt -map_metadata 1 -map_chapters 1 -codec copy "$BASE/episode-$EP.mp3"
NCH=$(ffprobe -v error -print_format json -show_chapters "$BASE/episode-$EP.mp3" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['chapters']))")
FIN=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$BASE/episode-$EP.mp3")
echo "驗證：episode-$EP.mp3　$NCH 個章節，實際長度 ${FIN}s"
cp "$SCRIPT" "$BASE/ep${EP}_script.txt"
rm -f unit_*.mp3 u_*.txt sil_*.mp3
