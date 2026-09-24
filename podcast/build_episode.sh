#!/bin/bash
# 用法: ./build_episode.sh <EP編號> <稿件路徑> <節目標題>
# 例:   ./build_episode.sh 006 ../../podcast_EP06稿.txt "EP06 諸子典籍與老莊"
set -e
EP=$1; SCRIPT=$2; TITLE=$3
BASE="/Users/candice/Documents/Candice_Claude/candice-site/podcast"
DIR="$BASE/ep$EP"
EDGE=/Users/candice/Library/Python/3.9/bin/edge-tts
mkdir -p "$DIR"; cd "$DIR"

# 1. 切章節
python3 - "$SCRIPT" <<'PYEOF'
import re,sys
txt=open(sys.argv[1],encoding='utf-8').read()
parts=re.split(r'===CHAPTER:\s*(.+?)===\n', txt)
ch=[(parts[i].strip(),parts[i+1].strip()) for i in range(1,len(parts),2)]
for idx,(t,b) in enumerate(ch,1):
    open(f'{idx:02d}.txt','w',encoding='utf-8').write(b)
open('titles.txt','w',encoding='utf-8').write('\n'.join(t for t,_ in ch))
print(f'切出 {len(ch)} 章，共 {sum(len(b) for _,b in ch)} 字')
PYEOF

# 2. 逐段轉檔 + 驗證速率（截斷會使速率異常偏高）
for f in [0-9][0-9].txt; do
  i="${f%.txt}"
  $EDGE --voice zh-TW-YunJheNeural -f "$f" --write-media "$i.mp3" 2>/dev/null
  D=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$i.mp3")
  C=$(python3 -c "print(len(open('$f',encoding='utf-8').read()))")
  python3 -c "
r=$C/$D
flag='截斷!!' if r>6.5 else 'ok'
print(f'  $i  {$D:7.1f}s  {$C:5d}字  {r:.2f}字/秒  {flag}')
"
done

# 3. 算章節時間、合併、寫入章節
python3 - "$TITLE" <<'PYEOF'
import subprocess,sys
title=sys.argv[1]
titles=open('titles.txt',encoding='utf-8').read().strip().split('\n')
files=[f'{i:02d}.mp3' for i in range(1,len(titles)+1)]
d=lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration',
  '-of','default=noprint_wrappers=1:nokey=1',f],capture_output=True,text=True).stdout.strip())
open('concat.txt','w').write('\n'.join(f"file '{f}'" for f in files))
meta=[';FFMETADATA1',f'title={title}','artist=Candice 的頻道']
t=0.0; lines=[]
for f,ct in zip(files,titles):
    du=d(f)
    meta+=['','[CHAPTER]','TIMEBASE=1/1000',f'START={int(t*1000)}',f'END={int((t+du)*1000)}',f'title={ct}']
    lines.append(f'{int(t//60):02d}:{int(t%60):02d} {ct}')
    t+=du
open('chapters.txt','w',encoding='utf-8').write('\n'.join(meta))
open('timestamps.txt','w',encoding='utf-8').write('\n'.join(lines))
print(f'\n總長 {int(t//60)}分{int(t%60)}秒')
print('\n'.join(lines))
PYEOF

# 4. 合併 + 嵌章節 + 驗證
ffmpeg -y -loglevel error -f concat -safe 0 -i concat.txt -c copy /tmp/ep$EP.mp3
ffmpeg -y -loglevel error -i /tmp/ep$EP.mp3 -i chapters.txt -map_metadata 1 -codec copy "$BASE/episode-$EP.mp3"
N=$(ffprobe -v error -print_format json -show_chapters "$BASE/episode-$EP.mp3" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['chapters']))")
echo "驗證：episode-$EP.mp3 內含 $N 個章節"
cp "$SCRIPT" "$BASE/ep${EP}_script.txt"
