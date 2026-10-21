#!/usr/bin/env python3
"""Build a task-local verification bundle and run native language checks in isolation."""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    project = Path(__file__).resolve().parents[1]
    app = root / 'One Cli Verification.app'
    contents = app / 'Contents'
    for directory in ('MacOS', 'Helpers', 'Resources'):
        (contents / directory).mkdir(parents=True, exist_ok=True)
    for binary in ('AIETerminal', 'AIEHookHelper', 'AIERemoteHelper'):
        target = contents / ('MacOS' if binary == 'AIETerminal' else 'Helpers') / binary
        shutil.copy2(args.bin_dir / binary, target)
    shutil.copytree(project / 'Resources', contents / 'Resources', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('Tools'))
    info = plistlib.loads((project / 'Resources/Info-Dev.plist').read_bytes())
    info.update(CFBundleIdentifier='com.aiterminal.verification', CFBundleName='One Cli Verification',
                CFBundleDisplayName='One Cli Verification')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    home, user = root / 'home', root / 'user-shell'
    home.mkdir(exist_ok=True)
    preferences = home / 'Library/Application Support/AITerminalVerification/appearance.json'
    preferences.parent.mkdir(parents=True, exist_ok=True)
    if not preferences.exists():
        preferences.write_text(json.dumps({'fontSize': 17, 'theme': 'Nord'}))
    user.mkdir(exist_ok=True)
    for name in ('.zshenv', '.zprofile', '.zlogin'):
        (user / name).write_text('')
    (user / '.zshrc').write_text("PROMPT='fixture> '\nHISTFILE=/dev/null\nSAVEHIST=0\n")
    # Only an alias lives outside the project: macOS Unix sockets have a 104-byte path limit.
    alias = Path('/private/tmp') / ('aie-lang-' + uuid.uuid4().hex[:8])
    alias.symlink_to(home, target_is_directory=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith(('AIE_', '_AIE_', 'CODEX_'))}
    env.update(CFFIXED_USER_HOME=str(alias), ZDOTDIR=str(user), TERM='xterm-256color')
    try:
        with (root / 'native.log').open('w') as log:
            result = subprocess.run([str(contents / 'MacOS/AIETerminal'), '--headless-language', '--workspace', str(root)],
                                    env=env, stdout=log, stderr=subprocess.STDOUT, timeout=100)
        report_path = root / 'native-language.json'
        if report_path.exists():
            print(json.dumps(json.loads(report_path.read_text()), ensure_ascii=False, indent=2))
        else:
            print((root / 'native.log').read_text()[-5000:])
        raise SystemExit(result.returncode)
    finally:
        alias.unlink()


if __name__ == '__main__':
    main()
