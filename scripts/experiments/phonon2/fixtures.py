#!/usr/bin/env python3
"""Freeze public fixtures before inference; replay verifies hashes, never accepts drift.

Audio and reference text remain in the local evaluation directory. The committed
manifest holds only provenance, identifiers, hashes, transformations and targets.
"""
import argparse
import array
import hashlib
import json
import math
import pathlib
import random
import subprocess
import urllib.parse
import urllib.request

SOURCES = [
    ('commands', 'PolyAI/minds14', '40ce77cb32a384e4d50a568e1ec39ac804019d33', 'en-AU', 'train', 28, 'transcription'),
    ('meeting', 'edinburghcstr/ami', '46f28f2503e2ec48f8867a84eef356c70476beab', 'ihm', 'train', 20, 'text'),
    ('multilingual', 'PolyAI/minds14', '40ce77cb32a384e4d50a568e1ec39ac804019d33', 'de-DE', 'train', 8, 'transcription'),
]
REVISIONS = {'FluidInference/phonon-2-coreml': 'a812a0dfef205660787ef6234317ab79acf4d5d6'}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def fetch(url):
    with urllib.request.urlopen(url, timeout=90) as response:
        return response.read()

def prepare(root):
    root.mkdir(parents=True, exist_ok=True)
    cases, entries = [], []
    for group, dataset, revision, config, split, count, field in SOURCES:
        query = urllib.parse.urlencode(dict(dataset=dataset, config=config, split=split))
        rows = json.loads(fetch('https://datasets-server.huggingface.co/first-rows?' + query))['rows']
        if group == 'commands':
            # MINDS rows are intent-sorted, so a prefix is not a command corpus.
            # Freeze the first two examples of EACH intent before inference.
            selected, counts = [], {}
            for offset in range(0, 700, 100):
                page = json.loads(fetch('https://datasets-server.huggingface.co/rows?' + query + f'&offset={offset}&length=100'))
                for item in page['rows']:
                    intent = item['row']['intent_class']
                    if counts.get(intent, 0) < 2:
                        selected.append(item); counts[intent] = counts.get(intent, 0) + 1
                if len(counts) == 14 and min(counts.values()) == 2: break
            if len(selected) != 28: raise ValueError('Expected all 14 MINDS intents')
        else:
            selected = rows[:count]
        for item in selected:
            index, row = item['row_idx'], item['row']
            identity = f'{group}-{index:03}'
            url = row['audio'][0]['src']
            if f'/--/{revision}/--/' not in url:
                raise ValueError('Dataset preview revision changed; fetch the pinned parquet instead, do not silently re-freeze.')
            wav = root / (identity + '.wav')
            if not wav.exists():
                wav.write_bytes(fetch(url))
            pcm = root / (identity + '.f32')
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(wav), '-ac', '1', '-ar', '16000', '-f', 'f32le', str(pcm)], check=True)
            raw = pcm.read_bytes()
            original_samples = len(raw)//4
            if original_samples < 16000:
                raw += bytes((16000-original_samples)*4)
                pcm.write_bytes(raw)
            reference = row[field]
            cases.append(dict(id=identity, group=group, pcm=str(pcm.resolve()), reference=reference, expectedSamples=len(raw)//4))
            entries.append(dict(id=identity, group=group, dataset=dataset, revision=revision, config=config, split=split,
                row=index, source_id=row.get('audio_id', row.get('path')), license='CC-BY-4.0',
                intent_class=row.get('intent_class'), reference_available=True, reference_sha256=digest(reference.encode()), wav_sha256=digest(wav.read_bytes()),
                pcm_sha256=digest(raw), samples=len(raw)//4, original_samples=original_samples, transform='ffmpeg mono 16kHz f32le; zero pad to 1s like Relay note adapter'))
    original = list(cases)
    for item in original[:5]:
        values = array.array('f', pathlib.Path(item['pcm']).read_bytes())
        rng = random.Random(411)
        rms = math.sqrt(sum(x*x for x in values)/len(values))
        noisy = array.array('f', (max(-1, min(1, x+rng.gauss(0, rms/10))) for x in values))
        identity = item['id'] + '-noise20db'
        path = root / (identity + '.f32'); path.write_bytes(noisy.tobytes())
        cases.append(dict(item, id=identity, group='commands-noise', pcm=str(path.resolve())))
        entries.append(dict(id=identity, derived_from=item['id'], pcm_sha256=digest(noisy.tobytes()), samples=len(noisy), transform='seed411 Gaussian noise 20dB SNR, clipped [-1,1]'))
    tail_case = next(item for item in original if item['group'] == 'commands' and 24000 <= item['expectedSamples'] <= 96000)
    tail = array.array('f', pathlib.Path(tail_case['pcm']).read_bytes())
    for seconds in [0.1, 1, 6, 14.999, 15, 15.001, 25, 31]:
        count = round(seconds*16000)
        if seconds == 0.1:
            data = tail[:count]; identity = 'boundary-raw-0.1'
        elif seconds == 1:
            data = tail[:1600] + array.array('f', [0]) * 14400; identity = 'boundary-padded-1'
        else:
            data = array.array('f', [0]) * (count-len(tail)) + tail; identity = f'boundary-tail-{seconds}'
        path = root / (identity + '.f32'); path.write_bytes(data.tobytes())
        cases.append(dict(id=identity, group='boundary', pcm=str(path.resolve()), reference=tail_case['reference'] if seconds>=6 else None, expectedSamples=len(data)))
        entries.append(dict(id=identity, derived_from=tail_case['id'], samples=len(data), pcm_sha256=digest(data.tobytes()), transform='speech at end after zero padding; short case crops first 0.1s, padded case adds 0.9s silence'))
    for version in ['v2', 'v3']:
        repo = f'FluidInference/parakeet-tdt-0.6b-{version}-coreml'
        REVISIONS[repo] = json.loads(pathlib.Path(__file__).with_name('corpus-v1.json').read_text())['model_revisions'][repo]
    return dict(schema_version=1, corpus_version='rr411-public-v2', sources=[dict(dataset=d, revision=r, license='CC-BY-4.0', attribution=f'https://huggingface.co/datasets/{d}/blob/{r}/README.md') for _,d,r,_,_,_,_ in SOURCES],
        model_revisions=REVISIONS, fixtures=entries,
        thresholds=dict(max_wer_regression_percentage_points=1, new_action_changing_errors=0, warm_p95_release_to_final_ms=500, warm_latency_regression_ms=0, note_p95_final_window_lag_ms=2000),
        coverage_gaps=['Relay-specific critical commands and proper names', 'natural environmental noise', 'simultaneous microphone/system sources', 'live capture timing', 'lower-end Mac and macOS 14']), dict(cases=cases, revisions=REVISIONS)

def main():
    p=argparse.ArgumentParser(); p.add_argument('directory',type=pathlib.Path); p.add_argument('--freeze',action='store_true')
    a=p.parse_args(); manifest_path=pathlib.Path(__file__).with_name('corpus-v2.json')
    manifest, inputs=prepare(a.directory)
    if a.freeze:
        if manifest_path.exists(): raise ValueError('Manifest already frozen')
        manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    else:
        frozen=json.loads(manifest_path.read_text())
        # Model HEAD may advance; frozen revisions remain authoritative on replay.
        manifest['model_revisions']=frozen['model_revisions']; inputs['revisions']=frozen['model_revisions']
        if manifest != frozen: raise ValueError('Fixture bytes or provenance changed')
    (a.directory/'input.json').write_text(json.dumps(inputs,indent=2)+'\n')
    print(f'Prepared {len(inputs["cases"])} public cases; manifest sha256 {digest(manifest_path.read_bytes())}')

if __name__=='__main__': main()
