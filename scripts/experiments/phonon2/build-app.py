#!/usr/bin/env python3
"""Build an uninstalled source copy with only candidate API adaptation.

Does not edit Relay's dependency pins or production selection. The temporary
copy is disposable and deliberately excludes lifecycle snapshots.
"""
import argparse
import io
import os
import pathlib
import subprocess
import tarfile

p = argparse.ArgumentParser()
p.add_argument('directory', type=pathlib.Path)
a = p.parse_args()
a.directory.mkdir(parents=True, exist_ok=False)
archive = subprocess.check_output(['git', 'archive', 'HEAD'])
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    tar.extractall(a.directory)
manifest = a.directory / 'Package.swift'
s = manifest.read_text()
assert s.count('from: "0.12.4"') == 1
s = s.replace('from: "0.12.4"', 'revision: "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7"')
manifest.write_text(s)
for relative in ['STT/STTEngine.swift', 'Notes/FluidAudioMeetingTranscriber.swift']:
    path = a.directory / 'Sources/relay-runner' / relative
    s = path.read_text()
    if relative.startswith('STT'):
        old = 'return try await manager.transcribe(audio, source: .microphone)'
        assert s.count(old) == 2
        s = s.replace(old, 'var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)\n                    return try await manager.transcribe(audio, decoderState: &state)')
    else:
        assert s.count('let source: AudioSource = request.sourceID == .microphone ? .microphone : .system') == 1
        assert s.count('manager.transcribe(samples, source: source)') == 1
        s = s.replace('let source: AudioSource = request.sourceID == .microphone ? .microphone : .system', 'var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)')
        s = s.replace('manager.transcribe(samples, source: source)', 'manager.transcribe(samples, decoderState: &state)')
    path.write_text(s)
env = dict(os.environ, SDKROOT='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk')
subprocess.run(['swift', 'build', '-c', 'release', '--product', 'relay-runner', '-j', '2', '--package-path', str(a.directory)], env=env, check=True)
