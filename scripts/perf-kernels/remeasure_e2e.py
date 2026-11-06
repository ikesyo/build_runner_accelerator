#!/usr/bin/env python3
"""Remeasure current-main E2E using prepared binaries and historical helpers.

Requires baseline/native/proposed binaries and eval/scripts/perf-kernels from
37c0194 under --results. Creates disposable fixtures; runs sequentially.
"""
import hashlib, itertools, json, os, re, shutil, statistics, subprocess, sys
from pathlib import Path

import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repository', type=Path, required=True)
parser.add_argument('--results', type=Path, required=True)
args = parser.parse_args()
ROOT = args.results.resolve()
REPO = args.repository.resolve()
DART=REPO/'.toolchains/dart/dart-sdk/bin/dart'
EVAL=ROOT/'eval/scripts/perf-kernels'
sys.path.insert(0,str(EVAL))
from paired_warm import marker, inventory
BINS={'baseline': ROOT/'baseline', 'native': ROOT/'native', 'proposal': ROOT/'proposed'}
ORDERS=list(itertools.permutations(BINS))
ENV=dict(os.environ, CARGO_HOME=str(REPO/'.toolchains/cargo'), RUSTUP_HOME=str(REPO/'.toolchains/rustup'), PUB_CACHE=str(REPO/'.pub-cache'), DART_BIN=str(DART), BUILD_RUNNER_ACCELERATOR_METRICS='0', BUILD_RUNNER_ACCELERATOR_WALL_TRACE='0', BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE='0')
ENV.pop('BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',None)
helper=(REPO/'scripts/benchmark_current_baseline.sh').read_text()
helper=re.sub(r'^script_dir=.*$', 'script_dir='+str(REPO/'scripts'), helper, count=1, flags=re.M)
helper=helper.replace('  remove_tree "$work_root"','  if [[ "${RETAIN_REMEASURE_WORKSPACE:-0}" == 1 ]]; then\n    printf "%s\\n" "$work_root" > "$results_dir/retained-workspace.txt"\n    return 0\n  fi\n  remove_tree "$work_root"',1)
(ROOT/'baseline-harness.sh').write_text(helper)
records=[]
expected=None
for repeat,order in enumerate(ORDERS):
    for variant in order:
        out=ROOT/'clean'/f'{repeat}.{variant}'
        env=ENV|{'LANE':'accelerator','COUNT':'500','CASES':'clean','REPEATS':'1','ACCELERATOR_JOBS':'2','PUB_GET_OFFLINE':'1','BUILD_RUNNER_ACCELERATOR_BIN':str(BINS[variant]),'RESULTS_DIR':str(out),'RETAIN_REMEASURE_WORKSPACE':str(int(repeat==5 and variant=='baseline'))}
        out.mkdir(parents=True)
        print('starting clean', repeat,variant,flush=True)
        with (out/'harness.log').open('w') as log:
            subprocess.run(['bash',str(ROOT/'baseline-harness.sh')],env=env,cwd=REPO,stdout=log,stderr=subprocess.STDOUT,check=True)
        record=json.loads((out/'default.clean.r1.json').read_text())
        outputs=json.loads((out/'default.clean.r1.outputs.json').read_text())['files']
        if expected is None: expected=outputs
        assert outputs==expected
        records.append(record|{'case':'clean','variant':variant,'repeat':repeat,'byte_identical':True})
        (ROOT/'clean-results.json').write_text(json.dumps(records,indent=2)+'\n')
        print('clean',repeat,variant,record['wall_ms'],flush=True)
work=Path((ROOT/'clean/5.baseline/retained-workspace.txt').read_text().strip())/'default/r1/clean'
(ROOT/'workspace.txt').write_text(str(work)+'\n')
command=[str(DART),'--suppress-analytics','run','build_runner_accelerator','build','--jobs','2']
cache=Path(str(work)+'.shared-cache')
aot=ROOT/'fixed-worker'
shutil.copy2(work/'.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker',aot,follow_symlinks=True)
fixed_digest=hashlib.sha256(aot.read_bytes()).hexdigest()
private=work/'.dart_tool/build_runner_accelerator'
out=ROOT/'warm';out.mkdir()
state=out/'variant-state';state.mkdir()
files=['graph-v3.bin','builder-manifest.json']
def env(variant): return ENV|{'BUILD_RUNNER_ACCELERATOR_BIN':str(BINS[variant]),'BUILD_RUNNER_ACCELERATOR_CACHE':str(cache),'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH':str(aot)}
def activate(variant):
    if (state/variant).exists():
        for name in files: shutil.copy2(state/variant/name,private/name)
def remember(variant):
    (state/variant).mkdir(exist_ok=True)
    for name in files: shutil.copy2(private/name,state/variant/name)
def restore(label,variant):
    activate(variant);marker(work,'base')
    with (out/(label+'.restore.log')).open('w') as log: subprocess.run(command,cwd=work,env=env(variant),stdout=log,stderr=subprocess.STDOUT,check=True)
for variant in BINS:
    restore('initial-'+variant,variant);remember(variant)
base=inventory(work);assert base==expected
references={'no-op':base}
for case,count in [('no-op',30),('one-file',12),('broad',6)]:
    for repeat in range(count):
        for variant in ORDERS[repeat%6]:
            label=f'{case}.{repeat}.{variant}'
            activate(variant)
            if case!='no-op':
                restore(label,variant);assert inventory(work)==base;marker(work,case)
            prefix=out/label
            subprocess.run(['python3',str(REPO/'scripts/measure_process.py'),'--metrics',str(prefix)+'.json','--stdout',str(prefix)+'.stdout','--stderr',str(prefix)+'.stderr','--cwd',str(work),'--label',label,'--',*command],env=env(variant),stdout=subprocess.DEVNULL,check=True)
            remember(variant)
            current=inventory(work)
            assert current.keys()==base.keys()
            changed=sum(digest!=base[name] for name,digest in current.items())
            assert changed=={'no-op':0,'one-file':1,'broad':500}[case]
            assert current==references.setdefault(case,current)
            assert hashlib.sha256(aot.read_bytes()).hexdigest()==fixed_digest
            record=json.loads(Path(str(prefix)+'.json').read_text())
            records.append(record|{'case':case,'variant':variant,'repeat':repeat,'byte_identical':True,'changed_output_count':changed})
            (ROOT/'all-results.json').write_text(json.dumps(records,indent=2)+'\n')
            print(label,record['wall_ms'],flush=True)
print('campaign complete',len(records),flush=True)
