#!/usr/bin/env python3
"""Verify loader-selected files against pinned Hub metadata; no model downloads."""
import argparse
import hashlib
import json
import pathlib
import urllib.request

p=argparse.ArgumentParser(); p.add_argument('directory',type=pathlib.Path); p.add_argument('output',type=pathlib.Path)
a=p.parse_args()
manifest=json.loads(pathlib.Path(__file__).with_name('corpus-v2.json').read_text())
report={}
for repo,revision in manifest['model_revisions'].items():
    url=f'https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true'
    remote={}
    while url:
        with urllib.request.urlopen(url,timeout=60) as response:
            for item in json.load(response):
                if item['type']=='file': remote[item['path']]=item
            link=response.headers.get('Link','')
            url=next((part.split('>')[0].strip().lstrip('<') for part in link.split(',') if 'rel="next"' in part),None)
    folder=a.directory/repo.split('/')[-1].removesuffix('-coreml')
    files=[]
    for path in sorted(folder.rglob('*')):
        if not path.is_file() or path.name.startswith('.'): continue
        relative=str(path.relative_to(folder))
        item=remote[relative]; data=path.read_bytes(); sha=hashlib.sha256(data).hexdigest()
        assert len(data)==item['size'], f'size mismatch: {relative}'
        if item.get('lfs'):
            expected=item['lfs']['oid']; actual=sha; algorithm='sha256'
        else:
            expected=item['oid']; actual=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest(); algorithm='git-blob-sha1'
        assert actual==expected, f'integrity mismatch: {relative}'
        files.append(dict(path=relative,bytes=len(data),sha256=sha,upstream_hash=expected,upstream_hash_algorithm=algorithm))
    assert files, 'no model files'
    report[repo]=dict(revision=revision,bytes=sum(x['bytes'] for x in files),files=files)
a.output.write_text(json.dumps(report,indent=2)+'\n')
print('All selected model files match pinned upstream objects')
