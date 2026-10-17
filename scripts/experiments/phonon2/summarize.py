#!/usr/bin/env python3
"""Reduce transcript-free evaluator JSONL; fail closed on missing cases/passes."""
import argparse
import hashlib
import json
import math
import pathlib


def p95(values):
    return sorted(values)[math.ceil(len(values)*0.95)-1]


def summarize(path, expected_ids):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
    prepared = [r for r in rows if r.get('event') == 'prepared']
    assert len(prepared) == 1, 'missing/duplicate preparation'
    results = [r for r in rows if r.get('event') in ['inference', 'rejected_short']]
    assert {(r['id'], r['iteration']) for r in results} == {(i,n) for i in expected_ids for n in range(4)}, 'incomplete evaluation'
    assert len(results) == len(expected_ids)*4, 'duplicate rows'
    groups = {}
    for group in sorted({r['group'] for r in results if 'group' in r}):
        first = [r for r in results if r.get('group') == group and r['iteration'] == 0]
        warm = [r for r in results if r.get('group') == group and r['iteration'] > 0]
        words = sum(r.get('reference_words',0) for r in first)
        errors = sum(r.get('word_errors',0) for r in first)
        groups[group] = dict(cases=len(first), reference_words=words, word_errors=errors,
            wer_percent=100*errors/words if words else None,
            first_pass_wall_p95_ms=p95([r['wall_ms'] for r in first]),
            warm_wall_p95_ms=p95([r['wall_ms'] for r in warm]),
            warm_model_p95_ms=p95([r['model_ms'] for r in warm]),
            assembly_mismatches=sum(not r['assembly_matches'] for r in first),
            punctuation_assembly_mismatches=sum(not r['assembly_text_matches'] for r in first),
            confidence_min=min((r['confidence_min'] for r in first if r['confidence_min'] is not None), default=None),
            confidence_max=max((r['confidence_max'] for r in first if r['confidence_max'] is not None), default=None),
            invalid_timings=sum(r['invalid_timings'] for r in first),
            tokens=sum(r['token_count'] for r in first),
            confidence_values=sum(r['confidence_count'] for r in first),
            leading_space_tokens=sum(r['leading_space_tokens'] for r in first),
            punctuation_tokens=sum(r['punctuation_tokens'] for r in first),
            warm_changed_error_counts=sum(r.get('word_errors') != next(x for x in first if x['id']==r['id']).get('word_errors') for r in warm))
    inferences = [r for r in results if r['event'] == 'inference']
    return dict(preparation_seconds=prepared[0]['seconds'], groups=groups,
        all_pass_diagnostics=dict(inferences=len(inferences),
            rejections=len(results)-len(inferences),
            assembly_mismatches=sum(not r['assembly_text_matches'] for r in inferences),
            invalid_timings=sum(r['invalid_timings'] for r in inferences),
            empty_token_results=sum(r['token_count']==0 for r in inferences)),
        boundaries=[r for r in results if r['id'].startswith('boundary') and r['iteration']==0],
        capture_to_first_partial_ms=None, release_to_final_ms=None, final_window_lag_ms=None,
        first_inference_ms=next(r['wall_ms'] for r in results if r['event']=='inference'))


def main():
    p=argparse.ArgumentParser(); p.add_argument('directory',type=pathlib.Path); p.add_argument('output',type=pathlib.Path)
    a=p.parse_args(); manifest_path=pathlib.Path(__file__).with_name('corpus-v2.json'); manifest=json.loads(manifest_path.read_text())
    result=dict(corpus_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(), runs={})
    for name,model in [('baseline-v2','v2'),('baseline-v3','v3'),('candidate-v2','v2'),('candidate-v3','v3'),('candidate-phonon2','phonon2')]:
        expected=[r['id'] for r in manifest['fixtures'] if r.get('group')!='multilingual' or model=='v3']
        result['runs'][name]=summarize(a.directory/(name+'.jsonl'),expected)
    result['paired_wer_delta_percentage_points']={group:result['runs']['candidate-phonon2']['groups'][group]['wer_percent']-result['runs']['baseline-v2']['groups'][group]['wer_percent'] for group in ['commands','meeting','commands-noise']}
    a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result['paired_wer_delta_percentage_points']))

if __name__=='__main__': main()
