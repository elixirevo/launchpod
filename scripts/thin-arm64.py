#!/usr/bin/env python3
"""Keep only the arm64 slice of embedded Mach-O files before code signing."""
from pathlib import Path
import subprocess
import sys

MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}

for path in Path(sys.argv[1]).rglob('*'):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) not in MAGIC:
            continue
    archs = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
    if 'arm64' not in archs:
        sys.exit(f'Embedded binary has no arm64 slice: {path}')
    if archs != ['arm64']:
        subprocess.run(['lipo', str(path), '-thin', 'arm64', '-output', str(path)], check=True)
    print(f'arm64: {path}')
