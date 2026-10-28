from pathlib import Path
import json,hashlib
p=Path('Sources/Kikishima/CaptionPanel.swift').read_text()
policy=Path('Sources/Kikishima/CaptionReadingPolicy.swift').read_text()
errors=[]
def check(ok,message):
 print(('PASS ' if ok else 'FAIL wiring: ')+message)
 if not ok:errors.append(message)
check('CaptionReadingPolicy.islandLayout(' in p and 'CaptionReadingPolicy.islandVisibleIDs(' in p,'island uses ordered queue and compact selector')
check('? islandLayoutResult.current == chunk.id' in p,'current marker uses queue current')
check('if islandLayoutResult.showsPending {' in p,'ASR cannot add a second current')
check('islandLayoutResult.history.count - (islandLayoutResult.history.firstIndex' in p,'age follows source order')
def block(s,name):
 a=s.index(name);b=s.index('{',a);i=b+1;depth=1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
record=json.loads(Path('tests/kk036_island_caption_order/baseline.json').read_text())
for name,want in record['desktop_functions'].items():
 check(hashlib.sha256(block(p,name).encode()).hexdigest()==want,'unchanged desktop '+name)
check(hashlib.sha256(policy[:record['policy_length']].encode()).hexdigest()==record['policy_sha256'],'all pre-existing policy code unchanged')
if errors:raise SystemExit(1)
