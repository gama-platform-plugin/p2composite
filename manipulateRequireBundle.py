#!/usr/bin/env python3
"""
Read or edit the Require-Bundle header in a MANIFEST.MF.

Usage:
  getRequireBundle.py MANIFEST.MF                        # print current value (flat CSV)
  getRequireBundle.py MANIFEST.MF --add id [id ...]      # add missing bundles
  getRequireBundle.py MANIFEST.MF --remove id [id ...]   # remove bundles
"""
import sys, re, argparse
from email.parser import HeaderParser

FOLD_WIDTH = 72


def read(path):
    return HeaderParser().parse(open(path)).get('Require-Bundle', '')


def fold(value):
    tokens = [t.strip() for t in value.split(',') if t.strip()]
    if not tokens:
        return 'Require-Bundle: '
    out, cur = [], 'Require-Bundle: '
    for i, tok in enumerate(tokens):
        seg = tok + (',' if i < len(tokens) - 1 else '')
        if len(cur + seg) <= FOLD_WIDTH:
            cur += seg
        else:
            out.append(cur)
            cur = ' ' + seg
    out.append(cur)
    return '\n'.join(out)


def write(path, value):
    txt = open(path).read()
    folded = fold(value)
    if re.search(r'^Require-Bundle:', txt, re.M):
        txt = re.sub(r'^Require-Bundle:(?:[^\n]+|\n[ \t].*)*', folded, txt, flags=re.M)
    else:
        txt = txt.rstrip('\n') + '\n' + folded + '\n'
    open(path, 'w').write(txt)


def bundle_id(spec):
    return re.split(r';', spec)[0].strip()


ap = argparse.ArgumentParser()
ap.add_argument('manifest')
ap.add_argument('--add',    nargs='*', default=None)
ap.add_argument('--remove', nargs='*', default=None)
args = ap.parse_args()

rb = read(args.manifest)

if args.add is None and args.remove is None:
    print(rb)
    sys.exit(0)

bundles = [t.strip() for t in rb.split(',') if t.strip()]
existing = {bundle_id(b) for b in bundles}

for spec in (args.remove or []):
    bid = bundle_id(spec)
    before = len(bundles)
    bundles = [b for b in bundles if bundle_id(b) != bid]
    print(f"  Require-Bundle {'- ' + bid if len(bundles) < before else '= ' + bid + ' (not found)'}", file=sys.stderr)

for spec in (args.add or []):
    bid = bundle_id(spec)
    if bid not in existing:
        bundles.append(spec)
        existing.add(bid)
        print(f"  Require-Bundle + {bid}", file=sys.stderr)
    else:
        print(f"  Require-Bundle = {bid} (already present)", file=sys.stderr)

write(args.manifest, ','.join(bundles))
