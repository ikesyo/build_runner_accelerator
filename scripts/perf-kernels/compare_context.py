#!/usr/bin/env python3
"""Compile exact dirty_context bodies against identical snapshots and graphs.

Run each compiled binary after all builds finish. Includes conversion/setup,
traversal and destruction. Uses the same allocator accounting as main.rs.
"""
import argparse
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline',default='origin/main')
p.add_argument('--results',required=True,type=Path)
p.add_argument('--rustc',required=True)
a=p.parse_args()
repo=Path(__file__).resolve().parents[2]
a.results.mkdir(parents=True,exist_ok=True)
header=(Path(__file__).parent/'src/main.rs').read_text().split('type Edges =')[0]
header=header.replace('use serde::Deserialize;','').replace('use serde_json::Value;','')
header=header.replace('#[allow(dead_code)]\n#[path = "../../../rust/src/digest.rs"]\nmod production_digest;\n','')
header+='''
#[derive(Clone)] struct AssetSnapshot { exists: bool, digest: String }
type Snapshot = BTreeMap<String,AssetSnapshot>;
struct GraphState { assets: Snapshot, resolver_dep_graph: BTreeMap<String,Vec<String>> }
#[allow(dead_code)] struct DirtyContext<'a> { changed: HashSet<&'a str>, tainted: HashSet<&'a str> }
'''
def body(source):
    start=source.index("    pub fn dirty_context<'a>")
    end=source.index('\n    #[cfg(test)]',start)
    return source[start:end]
baseline=body(subprocess.check_output(['git','show',f'{a.baseline}:rust/src/graph.rs'],cwd=repo,text=True))
proposal=body((repo/'rust/src/graph.rs').read_text())
driver='''
fn main() {
    println!("case,median_ns,allocations,peak_heap_bytes");
    for n in [64_usize,4096,32768] {
        let mut state=GraphState{assets:BTreeMap::new(),resolver_dep_graph:BTreeMap::new()};
        for i in 0..n {
            let id=format!("app|lib/model_{i:06}.dart");
            state.assets.insert(id.clone(),AssetSnapshot{exists:true,digest:"0123456789abcdef".into()});
            state.resolver_dep_graph.insert(id,vec![format!("app|lib/model_{:06}.dart",i.saturating_sub(1)),"app|lib/shared.dart".into()]);
        }
        for case in ["no-op","leaf","broad","disjoint"] {
            let mut current=state.assets.clone();
            if case=="leaf" {current.last_entry().unwrap().get_mut().digest.push('f');}
            if case=="broad" {current.insert("app|lib/shared.dart".into(),AssetSnapshot{exists:true,digest:"changed".into()});}
            if case=="disjoint" { current=current.into_iter().map(|(k,v)|(format!("z{k}"),v)).collect(); }
            let result=state.dirty_context(&current);
            let reference=state.reference(&current);
            assert_eq!(result.changed,reference.changed);
            assert_eq!(result.tainted,reference.tainted);
            measure(&format!("context/n{n}/{case}"),||{black_box(state.dirty_context(black_box(&current)));});
        }
    }
}
'''
for name,code,native in [('baseline',baseline,False),('native',baseline,True),('proposal',proposal,False)]:
    src=a.results/(name+'.rs')
    src.write_text(header+'impl GraphState {\n'+code+baseline.replace('fn dirty_context','fn reference')+'\n}\n'+driver)
    cmd=[a.rustc,'--edition=2024','-O',str(src),'-o',str(a.results/name)]
    if native: cmd+=['-C','target-cpu=native']
    subprocess.run(cmd,check=True)
print('Compilation complete. Execute baseline/native/proposal in rotated order.')
