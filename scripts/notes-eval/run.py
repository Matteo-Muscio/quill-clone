#!/usr/bin/env python3
"""Local-only evaluation runner. Requires the built native preview and installed models.

Runs authored transcript fixtures serially through the actual Quill engine. It never
sends the expected/forbidden checklists to a model. Output is intentionally kept out
of the repository. Use --monitor-pid for an actual UI run with transcription loaded.
RSS and physical-footprint sums are sampled process metrics, not system memory use.
"""
import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import subprocess
import time
import unicodedata


class RUsageV2(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
        'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime',
        'proc_exit_abstime', 'child_user_time', 'child_system_time',
        'child_pkg_idle_wkups', 'child_interrupt_wkups', 'child_pageins',
        'child_elapsed_abstime', 'diskio_bytesread', 'diskio_byteswritten')]


libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int


def usage(pid):
    value = RUsageV2()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(value)) != 0:
        return None
    return {'rssBytes': value.resident_size, 'physicalFootprintBytes': value.phys_footprint}


def processes(parent):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,comm='], text=True)
    entries = []
    for row in rows.splitlines():
        values = row.split(None, 2)
        if len(values) == 3:
            entries.append((int(values[0]), int(values[1]), values[2]))
    descendants = {parent}
    while True:
        found = {pid for pid, ppid, _ in entries if ppid in descendants}
        if found <= descendants:
            break
        descendants |= found
    result = []
    for pid, _, command in entries:
        if pid in descendants:
            value = usage(pid)
            if value is not None:
                result.append(dict(pid=pid, executable=pathlib.Path(command).name, **value))
    return result


def swap():
    return subprocess.check_output(['/usr/sbin/sysctl', '-n', 'vm.swapusage'], text=True).strip()


def monitor(pid, finished):
    started = time.time()
    samples = []
    swap_before = swap()
    baseline = usage(pid)
    while not finished():
        current = processes(pid)
        if current:
            samples.append({'elapsed': time.time() - started, 'processes': current,
                'rssBytes': sum(item['rssBytes'] for item in current),
                'physicalFootprintBytes': sum(item['physicalFootprintBytes'] for item in current)})
        time.sleep(0.25)
    workers = [item for s in samples for item in s['processes']
               if item['executable'] in ('llama-completion', 'llama-tokenize')]
    return {'sampleIntervalSeconds': 0.25, 'baselineParent': baseline,
        'peakAppAndChildrenRSSBytes': max((s['rssBytes'] for s in samples), default=0),
        'peakAppAndChildrenPhysicalFootprintBytes': max((s['physicalFootprintBytes'] for s in samples), default=0),
        'peakSingleWorkerRSSBytes': max((p['rssBytes'] for p in workers), default=0),
        'peakSingleWorkerPhysicalFootprintBytes': max((p['physicalFootprintBytes'] for p in workers), default=0),
        'swapBefore': swap_before, 'swapAfter': swap(), 'samples': samples}


def normalized(value):
    return ' '.join(''.join(c for c in unicodedata.normalize('NFKC', value).casefold()
                           if not unicodedata.category(c).startswith('P')).split())


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def private_output(path):
    # Tighten an existing output before truncation, and never follow a link to
    # an original input or another file outside this evaluation directory.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        os.ftruncate(descriptor, 0)
        return os.fdopen(descriptor, 'w', encoding='utf-8')
    except BaseException:
        os.close(descriptor)
        raise


def write_private(path, text):
    with private_output(path) as output:
        output.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview', type=pathlib.Path)
    parser.add_argument('--cases', type=pathlib.Path, default=pathlib.Path(__file__).with_name('cases.json'))
    parser.add_argument('--model', default='qwen3.5-2b-q4_k_m')
    parser.add_argument('--strategy', choices=['singlePass', 'evidenceFirst', 'verifiedEvidence'], default='evidenceFirst')
    parser.add_argument('--options', type=pathlib.Path, help='Developer generation options JSON; omitted preserves app defaults')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--only', help='Comma-separated case IDs for a canary')
    parser.add_argument('--monitor-pid', type=int)
    args = parser.parse_args()
    os.umask(0o077)
    private_directory(args.output)
    if args.monitor_pid:
        stop = args.output / 'stop'
        if stop.exists():
            parser.error('Choose a fresh monitor output directory; its stop file already exists')
        result = monitor(args.monitor_pid, stop.exists)
        write_private(args.output / 'memory.json', json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'samples'}, indent=2))
        return
    if not args.preview or not args.preview.is_file():
        parser.error('--preview must name the built QuillMeetingPreview executable')
    options = None
    options_hash = None
    if args.options:
        args.options = args.options.resolve(strict=True)
        raw_options = args.options.read_bytes()
        options = json.loads(raw_options)
        if not isinstance(options, dict):
            parser.error('--options must contain a JSON object')
        options_hash = hashlib.sha256(raw_options).hexdigest()
    selected = set(args.only.split(',')) if args.only else None
    cases = json.loads(args.cases.read_text())['cases']
    runs_path = args.output / 'runs.json'
    runs = json.loads(runs_path.read_text()) if runs_path.exists() else []
    for case in cases:
        if selected is not None and case['id'] not in selected:
            continue
        folder = args.output / case['id']
        private_directory(folder)
        output = folder / 'notes.json'
        if output.exists():
            parser.error('Refusing to overwrite an earlier output: ' + str(output))
        source = folder / 'source.md'
        write_private(source, case['transcript'])
        with private_output(folder / 'run.log') as log:
            command = [str(args.preview), 'notes', str(source), args.model, args.strategy, str(output)]
            if args.options:
                command.append(str(args.options))
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            memory = monitor(child.pid, lambda: child.poll() is not None)
            status = child.wait()
        write_private(folder / 'memory.json', json.dumps(memory, indent=2) + '\n')
        result = {'case': case['id'], 'model': args.model, 'strategy': args.strategy, 'exitCode': status}
        if options is not None:
            result.update(requestedOptions=options, optionsSHA256=options_hash)
        if output.exists():
            notes = json.loads(output.read_text())
            metrics = json.loads(output.with_suffix('.json.metrics.json').read_text())
            result.update(metrics)
            result['languageMatches'] = metrics['outputLanguage'] == case['language']
            points = notes.get('keyTakeaways', [])
            result['duplicateTakeaways'] = len(points) - len(set(map(normalized, points)))
            ids = {s['id'] for s in notes.get('sources', [])}
            result['invalidSourceIDs'] = sorted({id for c in notes.get('citations', []) for id in c['sourceIDs'] if id not in ids})
            result['citationCount'] = len(notes.get('citations', []))
        result['peakPhysicalFootprintBytes'] = memory['peakAppAndChildrenPhysicalFootprintBytes']
        runs.append(result)
        print(json.dumps(result), flush=True)
        write_private(runs_path, json.dumps(runs, indent=2) + '\n')
    if any(run['exitCode'] != 0 for run in runs):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
