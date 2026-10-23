#!/usr/bin/env python3
"""Delete the vcfops-synth views, reports and dashboards on a VCF Operations appliance with ops-cli.

The Suite API cannot delete views, reports or dashboards; ops-cli on the appliance
can, by exact name. `reset -IncludeContent` writes the names to content-delete.json
in the data folder. Copy that file and this script to the appliance, then, as root:

    $VMWARE_PYTHON_BIN ops-content-delete.py content-delete.json          # report only
    $VMWARE_PYTHON_BIN ops-content-delete.py content-delete.json --apply  # delete

Every name must start with the payload's prefix. A name that starts with '-'
(ops-cli's -all deletes every item, the built-in ones too) or holds a comma
(ops-cli's name separator) is refused. Dashboards are deleted for the payload's
owner (the user content imported them as), or for all users when it names none.

VCF Operations 9.1.1 ships opscli.jar asking for lib/slf4j-api-2.0.17.jar while lib
holds 2.0.18, so ops-cli fails with NoClassDefFoundError. When a jar the manifest
names is missing and lib holds another version of it, that version goes on the
boot classpath (JDK_JAVA_OPTIONS) for these ops-cli calls only; nothing on the
appliance is changed.
Exit code 0 when nothing failed, 1 when an item failed, 2 for a bad payload.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import zipfile

OPSCLI_DIR = '/usr/lib/vmware-vcops/tools/opscli'
# ops-cli 9.1.1 on a missing name (exit 3): "View definition(s) <n> was not found.",
# "Report definition(s) <n> was not found.", "Dashboard <n> not found for user <u>".
NOT_THERE = {
    'view': lambda name, owner: 'definition(s) %s was not found' % name,
    'report': lambda name, owner: 'definition(s) %s was not found' % name,
    'dashboard': lambda name, owner: 'Dashboard %s not found for user %s' % (name, owner) if owner else 'Dashboard %s not found for user' % name,
}
# ops-cli's Java start-up chatter, left out of a failure's message.
NOISE = re.compile(r'^(INFO:|WARNING:|[A-Z][a-z]{2} \d+, \d{4} .*(PM|AM) org\.|VMware Cloud|Starting VMware|\s*$)')


def load_items(path):
    with open(path, encoding='utf-8-sig') as f:
        payload = json.load(f)
    prefix = payload.get('prefix') or ''
    if not prefix.strip():
        raise ValueError('the payload has no prefix')
    owner = str(payload.get('owner') or '').strip()
    if owner and (owner.startswith('-') or ',' in owner or ' ' in owner):
        raise ValueError('the owner must not start with - or hold a comma or space')
    items = []
    # Reports and dashboards first: ops-cli will not delete a view a report still uses.
    for kind in ('report', 'dashboard', 'view'):
        for name in payload.get(kind) or []:
            items.append((kind, str(name)))
    return prefix, owner, items


def missing_jar_options(opscli_dir):
    """JDK_JAVA_OPTIONS adding lib's version of each jar opscli.jar's manifest names but lib lacks; '' when none."""
    lib = os.path.join(opscli_dir, 'lib')
    try:
        with zipfile.ZipFile(os.path.join(opscli_dir, 'opscli.jar')) as jar:
            manifest = jar.read('META-INF/MANIFEST.MF').decode('utf-8', 'replace')
        present = os.listdir(lib)
    except (OSError, KeyError, zipfile.BadZipFile):
        return ''
    # Manifest lines wrap at 72 bytes; a continuation line starts with one space.
    manifest = manifest.replace('\r\n', '\n').replace('\n ', '')
    match = re.search(r'^Class-Path:(.*)$', manifest, re.MULTILINE)
    add = []
    for entry in (match.group(1).split() if match else []):
        name = os.path.basename(entry)
        if not name.endswith('.jar') or name in present:
            continue
        artifact = re.match(r'(.+?)-\d[\w.]*\.jar$', name)
        if not artifact:
            continue
        found = sorted(f for f in present if re.match(re.escape(artifact.group(1)) + r'-\d[\w.]*\.jar$', f))
        if found:
            add.append(os.path.join(lib, found[-1]))
    return '-Xbootclasspath/a:' + ':'.join(add) if add else ''


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
    parser.add_argument('--jsonl', action='store_true', help='one JSON object per item, for reset -ApplianceSsh')
    parser.add_argument('--opscli-dir', default=OPSCLI_DIR, help='folder holding ops-cli.py (default %(default)s)')
    args = parser.parse_args()

    try:
        prefix, owner, items = load_items(args.payload)
    except (OSError, ValueError) as e:
        print('Cannot read the payload: %s' % e, file=sys.stderr)
        return 2
    opscli = os.path.join(args.opscli_dir, 'ops-cli.py')
    if args.apply and not os.path.isfile(opscli):
        print('ops-cli.py not found in %s' % args.opscli_dir, file=sys.stderr)
        return 2

    env = os.environ.copy()
    if args.apply:
        extra = missing_jar_options(args.opscli_dir)
        if extra:
            env['JDK_JAVA_OPTIONS'] = (env.get('JDK_JAVA_OPTIONS', '') + ' ' + extra).strip()

    def emit(action, kind, name, error=None):
        if args.jsonl:
            print(json.dumps({'action': action, 'kind': kind, 'name': name, 'error': error}))
        else:
            print('  %-14s %-10s %s' % (action, kind, name) + (' (%s)' % error if action == 'refused' else ''))
            if action == 'failed':
                print('    %s' % error)

    failed = 0
    for kind, name in items:
        reason = refusal(prefix, name)
        if reason:
            failed += 1
            emit('refused', kind, name, reason)
            continue
        if not args.apply:
            emit('would delete', kind, name)
            continue
        cmd = [sys.executable, opscli, kind, 'delete'] + ([owner or 'all'] if kind == 'dashboard' else []) + [name]
        run = subprocess.run(cmd, cwd=args.opscli_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = run.stdout.strip()
        # A clean exit first: deleting for all users also prints "not found" for every user without it.
        if run.returncode == 0:
            action = 'deleted'
        elif NOT_THERE[kind](name, owner) in output:
            action = 'not there'
        else:
            action = 'failed'
            failed += 1
        detail = [line for line in output.splitlines() if not NOISE.match(line)][-3:]
        emit(action, kind, name, 'exit %d: %s' % (run.returncode, ' | '.join(detail)) if action == 'failed' else None)

    if not args.apply and not args.jsonl:
        print('Report only: nothing was deleted. Add --apply to delete.')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
