#!/usr/bin/env python3
"""Build the RR-416 note soak outside the source tree (Swift 6.0+, macOS 14+).

Copies the production note producer, contracts, recording transcriber,
FluidAudio note adapter and model resolver so the soak exercises the shipped
windowing, queueing and post-Stop paths.
"""
import argparse
import os
import pathlib
import shutil
import subprocess

PIN = '0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7'
APP = pathlib.Path(__file__).resolve().parents[3] / 'Sources' / 'relay-runner'
COPIED = [
    'Notes/MeetingTranscriptProducer.swift',
    'Notes/MeetingTranscriptionContracts.swift',
    'Notes/MeetingRecordingTranscriber.swift',
    'Notes/FluidAudioMeetingTranscriber.swift',
    'STT/STTModelSelection.swift',
]
LOCAL = ['notesoak.swift', 'notesoak-stubs.swift']

def main():
    p = argparse.ArgumentParser()
    p.add_argument('directory', type=pathlib.Path)
    a = p.parse_args()
    a.directory.mkdir(parents=True, exist_ok=True)
    for name in LOCAL:
        shutil.copyfile(pathlib.Path(__file__).with_name(name), a.directory / name)
    for path in COPIED:
        shutil.copyfile(APP / path, a.directory / pathlib.Path(path).name)
    sources = LOCAL + [pathlib.Path(path).name for path in COPIED]
    (a.directory / 'Package.swift').write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RR416NoteSoak", platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "{PIN}")],
    targets: [.executableTarget(name: "notesoak", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
        path: ".", sources: [{", ".join(chr(34) + s + chr(34) for s in sources)}], swiftSettings: [.swiftLanguageMode(.v5)])])
''')
    env = dict(os.environ)
    env['SDKROOT'] = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(a.directory), '-j', '4'], check=True, env=env)

if __name__ == '__main__':
    main()
