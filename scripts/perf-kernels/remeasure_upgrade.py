#!/usr/bin/env python3
"""Measure three ordinary-launcher cache upgrades after remeasure_e2e.py."""
import json, os, subprocess, sys
from pathlib import Path
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repository', type=Path, required=True)
parser.add_argument('--results', type=Path, required=True)
args = parser.parse_args()
ROOT = args.results.resolve()
REPO = args.repository.resolve()
sys.path.insert(0,str(ROOT/'eval/scripts/perf-kernels'))
from paired_warm import inventory, marker
work=Path((ROOT/'workspace.txt').read_text().strip())
dart=REPO/'.toolchains/dart/dart-sdk/bin/dart'
cmd=[str(dart),'--suppress-analytics','run','build_runner_accelerator','build','--jobs','2']
env=dict(os.environ,PUB_CACHE=str(REPO/'.pub-cache'),BUILD_RUNNER_ACCELERATOR_METRICS='0',BUILD_RUNNER_ACCELERATOR_WALL_TRACE='0',BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE='0')
env.pop('BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',None)
marker(work,'base')
records=[]
for repeat in range(3):
 out=ROOT/'upgrade'/str(repeat);out.mkdir(parents=True)
 env['BUILD_RUNNER_ACCELERATOR_CACHE']=str(ROOT/f'upgrade-cache-{repeat}')
 env['BUILD_RUNNER_ACCELERATOR_BIN']=str(ROOT/'baseline')
 print('baseline preparation',repeat,flush=True)
 with (out/'baseline-preparation.log').open('w') as log:
  subprocess.run(cmd,cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 expected=inventory(work);assert len(expected)==1001
 for label in ['baseline-steady','upgrade','steady']:
  if label!='baseline-steady':env['BUILD_RUNNER_ACCELERATOR_BIN']=str(ROOT/'proposed')
  prefix=out/label
  subprocess.run(['python3',str(REPO/'scripts/measure_process.py'),'--metrics',str(prefix)+'.json','--stdout',str(prefix)+'.stdout','--stderr',str(prefix)+'.stderr','--cwd',str(work),'--label',label,'--',*cmd],cwd=REPO,env=env,stdout=subprocess.DEVNULL,check=True)
  assert inventory(work)==expected
  record=json.loads(Path(str(prefix)+'.json').read_text())|{'case':label,'repeat':repeat,'byte_identical':True}
  records.append(record)
  (ROOT/'upgrade-results.json').write_text(json.dumps(records,indent=2)+'\n')
  print(repeat,label,record['wall_ms'],flush=True)
