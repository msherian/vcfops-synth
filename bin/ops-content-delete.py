#!/usr/bin/env python3
"""Delete the vcfops-synth views, reports and dashboards on a VCF Operations appliance with ops-cli.

The Suite API cannot delete views, reports or dashboards; ops-cli on the appliance
can, by exact name. `reset -IncludeContent` writes the names to content-delete.json
in the data folder. Copy that file and this script to the appliance, then, as root:

    $VMWARE_PYTHON_BIN ops-content-delete.py content-delete.json          # report only
    $VMWARE_PYTHON_BIN ops-content-delete.py content-delete.json --apply  # delete

Every name must start with the payload's prefix. A name that starts with '-'
(ops-cli's -all deletes every item, the built-in ones too) or holds a comma
(ops-cli's name separator) is refused. Dashboards are deleted for all users.
Exit code 0 when nothing failed, 1 when an item failed, 2 for a bad payload.
"""
import argparse
import json
import os
import re
import subprocess
import sys

OPSCLI_DIR = '/usr/lib/vmware-vcops/tools/opscli'
NOT_THERE = re.compile(r'not (found|exist)|does ?n.t exist|no such', re.IGNORECASE)
FAILED = re.compile(r'\b(error|fail(ed|ure)?|exception)\b', re.IGNORECASE)


def load_items(path):
    with open(path, encoding='utf-8-sig') as f:
        payload = json.load(f)
    prefix = payload.get('prefix') or ''
    if not prefix.strip():
        raise ValueError('the payload has no prefix')
    items = []
    for kind in ('view', 'report', 'dashboard'):
        for name in payload.get(kind) or []:
            items.append((kind, str(name)))
    return prefix, items


def refusal(prefix, name):
    if not name.startswith(prefix):
        return 'the name does not start with the prefix'
    if name.startswith('-') or ',' in name:
        return 'the name starts with - or holds a comma'
    return None


def main():
    parser = argparse.ArgumentParser(description='Delete the vcfops-synth views, reports and dashboards with ops-cli.')
    parser.add_argument('payload', help='content-delete.json written by reset -IncludeContent')
    parser.add_argument('--apply', action='store_true', help='delete for real; without it, report only')
    parser.add_argument('--opscli-dir', default=OPSCLI_DIR, help='folder holding ops-cli.py (default %(default)s)')
    args = parser.parse_args()

    try:
        prefix, items = load_items(args.payload)
    except (OSError, ValueError) as e:
        print('Cannot read the payload: %s' % e, file=sys.stderr)
        return 2
    opscli = os.path.join(args.opscli_dir, 'ops-cli.py')
    if args.apply and not os.path.isfile(opscli):
        print('ops-cli.py not found in %s' % args.opscli_dir, file=sys.stderr)
        return 2

    failed = 0
    for kind, name in items:
        reason = refusal(prefix, name)
        if reason:
            failed += 1
            print('  %-14s %-10s %s (%s)' % ('refused', kind, name, reason))
            continue
        if not args.apply:
            print('  %-14s %-10s %s' % ('would delete', kind, name))
            continue
        cmd = [sys.executable, opscli, kind, 'delete'] + (['all'] if kind == 'dashboard' else []) + [name]
        run = subprocess.run(cmd, cwd=args.opscli_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = run.stdout.strip()
        if NOT_THERE.search(output):
            action = 'not there'
        elif run.returncode == 0 and not FAILED.search(output):
            action = 'deleted'
        else:
            action = 'failed'
            failed += 1
        print('  %-14s %-10s %s' % (action, kind, name))
        if action == 'failed':
            print('    exit %d: %s' % (run.returncode, output))

    if not args.apply:
        print('Report only: nothing was deleted. Add --apply to delete.')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
