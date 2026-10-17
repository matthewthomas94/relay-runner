#!/usr/bin/env python3
"""Prepare via FluidAudio, then run serial offline comparisons after builds finish."""
import argparse
import json
import hashlib
import os
import pathlib
import subprocess

p=argparse.ArgumentParser(); p.add_argument('mode',choices=['prepare','measure']);p.add_argument('directory',type=pathlib.Path)
a=p.parse_args(); root=a.directory.resolve(); source=pathlib.Path(__file__).resolve().parent
folders={'v2':'parakeet-tdt-0.6b-v2','v3':'parakeet-tdt-0.6b-v3','phonon2':'phonon-2'}
env={k:v for k,v in os.environ.items() if not k.startswith(('TDT_','ASR_'))}
input_path=root/'fixtures-v2/input.json'
manifest=json.loads((source/'corpus-v2.json').read_text())
inputs=json.loads(input_path.read_text())
assert inputs['revisions']==manifest['model_revisions'], 'model pin drift'
entries={x['id']:x for x in manifest['fixtures']}
assert set(entries)=={x['id'] for x in inputs['cases']}, 'fixture identity drift'
for case in inputs['cases']:
    entry=entries[case['id']]
    data=pathlib.Path(case['pcm']).read_bytes()
    assert hashlib.sha256(data).hexdigest()==entry['pcm_sha256'], 'PCM drift'
    assert len(data)==4*case['expectedSamples']==4*entry['samples'], 'sample drift'
    if case['reference'] is not None:
        reference=entry if 'reference_sha256' in entry else entries[entry['derived_from']]
        assert hashlib.sha256(case['reference'].encode()).hexdigest()==reference['reference_sha256'], 'reference drift'

if a.mode=='prepare':
    runs=[('candidate',m) for m in folders]
else:
    # Audit must succeed before any paired measurements. Files are not modified.
    subprocess.run(['python3',str(source/'audit-models.py'),str(root/'models'),str(root/'model-files.json')],check=True)
    runs=[('baseline','v2'),('candidate','phonon2'),('candidate','v2'),('baseline','v3'),('candidate','v3')]
    env['RR411_OFFLINE']='1'
for runtime,model in runs:
    executable=root/runtime/'.build/release/evaluator'
    command=[str(executable),model,str(root/'models'/folders[model]),str(input_path),'0' if a.mode=='prepare' else '4']
    if a.mode=='measure':
        command=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)']+command
    name=f'{runtime}-{model}'
    with (root/(name+('.prepare.jsonl' if a.mode=='prepare' else '.jsonl'))).open('w') as out, (root/(name+'.stderr')).open('w') as err:
        subprocess.run(command,stdout=out,stderr=err,env=env,check=True)
    print(f'{a.mode} {name}: passed',flush=True)
