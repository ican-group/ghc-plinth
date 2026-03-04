#!/usr/bin/env python
# -*- coding: utf-8 -*-

from pathlib import Path
import urllib.request
import ssl
import subprocess
import argparse
import sys
from sys import stderr

# On Windows (MSYS2/MinGW), Python's bundled OpenSSL may not find
# system CA certificates. Build a context that tries multiple sources.
def _make_ssl_context():
    ctx = ssl.create_default_context()
    if ctx.cert_store_stats()['x509_ca'] > 0:
        return ctx
    import os
    # Try common CA bundle locations (Windows paths for native Python)
    candidates = [os.environ.get('SSL_CERT_FILE', '')]
    # Add Git for Windows and MSYS2 paths
    for prefix in ['C:/Program Files/Git', 'C:/msys64']:
        candidates.append(prefix + '/mingw64/etc/ssl/certs/ca-bundle.crt')
        candidates.append(prefix + '/usr/ssl/certs/ca-bundle.crt')
    for ca in candidates:
        if ca and os.path.isfile(ca):
            try:
                ctx.load_verify_locations(ca)
                return ctx
            except Exception:
                pass
    return ctx

_ssl_ctx = _make_ssl_context()
_https_handler = urllib.request.HTTPSHandler(context=_ssl_ctx)
_opener = urllib.request.build_opener(_https_handler)
urllib.request.install_opener(_opener)

TARBALL_VERSION = '0.8'
BASE_URL = "https://downloads.haskell.org/ghc/mingw/{}".format(TARBALL_VERSION)
DEST = Path('ghc-tarballs/mingw-w64')
ARCHS = ['x86_64', 'sources']

def file_url(arch: str, fname: str) -> str:
    return "{base}/{arch}/{fname}".format(
        base=BASE_URL,
        arch=arch,
        fname=fname)

def fetch(url: str, dest: Path):
    print('Fetching', url, '=>', dest, file=stderr)
    urllib.request.urlretrieve(url, dest)

def fetch_arch(arch: str):
    manifest_url = file_url(arch, 'MANIFEST')
    print('Fetching', manifest_url, file=stderr)
    req = urllib.request.urlopen(manifest_url)
    files = req.read().decode('UTF-8').split('\n')
    d = DEST / arch
    if not d.is_dir():
        d.mkdir(parents=True)
    fetch(file_url(arch, 'SHA256SUMS'), d / 'SHA256SUMS')
    for fname in files:
        if not (d / fname).is_file():
            fetch(file_url(arch, fname), d / fname)

    verify(arch)

def list_arch(arch: str):
    d = DEST / arch
    manifest_url = file_url(arch, 'MANIFEST')
    req = urllib.request.urlopen(manifest_url)
    files = req.read().decode('UTF-8').split('\n')
    print(d / 'SHA256SUMS')
    for fname in files:
      print(d / fname)

def verify(arch: str):
    if not Path(DEST / arch / "SHA256SUMS").is_file():
        print("SHA256SUMS doesn't exist; have you fetched?", file=stderr)
        sys.exit(2)

    cmd = ['sha256sum', '--quiet', '--check', '--ignore-missing', 'SHA256SUMS']
    subprocess.check_call(cmd, cwd=DEST / arch)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['verify', 'download', 'list'])
    parser.add_argument(
        'arch',
        choices=ARCHS + ['all'],
        help="Architecture to fetch (either x86_64, sources, or all)")
    args = parser.parse_args()

    action = { 'download' : fetch_arch, 'verify' : verify, 'list' : list_arch }[args.mode]
    if args.arch == 'all':
        for arch in ARCHS:
            action(arch)
    else:
        action(args.arch)

if __name__ == '__main__':
    main()
