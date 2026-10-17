#!/usr/bin/env python3
"""Build both pinned evaluators outside the source tree (Swift 6.0+, macOS 14+)."""
import argparse
import pathlib
import os
import shutil
import subprocess

PINS = {'baseline': '57551cd90e0bbec342766244358bcf08afb05290',
        'candidate': '0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7'}

def main():
    p = argparse.ArgumentParser()
    p.add_argument('kind', choices=PINS)
    p.add_argument('directory', type=pathlib.Path)
    a = p.parse_args()
    a.directory.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(pathlib.Path(__file__).with_name('main.swift'), a.directory / 'main.swift')
    flags = '[.define("BASELINE")]' if a.kind == 'baseline' else '[]'
    (a.directory / 'Package.swift').write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RR411Evaluation", platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "{PINS[a.kind]}")],
    targets: [.executableTarget(name: "evaluator", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
        path: ".", sources: ["main.swift"], swiftSettings: {flags})])
''')
    env = dict(os.environ)
    # Use the SDK shipped with the selected Xcode compiler, avoiding a newer CLT SDK.
    env['SDKROOT'] = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(a.directory), '-j', '4'], check=True, env=env)

if __name__ == '__main__':
    main()
