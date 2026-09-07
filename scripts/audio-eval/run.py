#!/usr/bin/env python3
"""Serial, local ASR comparisons using explicitly supplied audio variants.

This script performs no preprocessing, model download, diarization or inference
itself. The native preview loads an already installed Parakeet model. A reference
is optional and is never invented or inferred from another recognizer's output.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import subprocess
import time
import unicodedata


def normalized(text):
    """NFKC + casefold; punctuation becomes space; whitespace is collapsed."""
    folded = unicodedata.normalize('NFKC', text).casefold()
    return ' '.join(''.join(' ' if unicodedata.category(char).startswith('P') else char
                            for char in folded).split())


def word_edits(reference, hypothesis):
    """Minimum token edits with counts; ties prefer substitution, deletion, insertion."""
    previous = [(j, 0, 0, j) for j in range(len(hypothesis) + 1)]
    for i, ref in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, hyp in enumerate(hypothesis, 1):
            if ref == hyp:
                current.append(previous[j - 1])
                continue
            distance, sub, delete, insert = previous[j - 1]
            substitution = (distance + 1, sub + 1, delete, insert)
            distance, sub, delete, insert = previous[j]
            deletion = (distance + 1, sub, delete + 1, insert)
            distance, sub, delete, insert = current[j - 1]
            insertion = (distance + 1, sub, delete, insert + 1)
            current.append(min((substitution, deletion, insertion), key=lambda value: value[0]))
        previous = current
    distance, substitutions, deletions, insertions = previous[-1]
    return {'distance': distance, 'substitutions': substitutions,
            'deletions': deletions, 'insertions': insertions}


def character_distance(reference, hypothesis):
    """Levenshtein distance with linear working memory."""
    if len(hypothesis) > len(reference):
        reference, hypothesis = hypothesis, reference
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        current = [i]
        for j, hyp in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ref != hyp)))
        previous = current
    return previous[-1]


def error_rates(reference, hypothesis):
    ref, hyp = normalized(reference), normalized(hypothesis)
    words = word_edits(ref.split(), hyp.split())
    ref_chars, hyp_chars = ref.replace(' ', ''), hyp.replace(' ', '')
    char_errors = character_distance(ref_chars, hyp_chars)
    word_count, char_count = len(ref.split()), len(ref_chars)
    # A nonempty hypothesis against an empty reference has no finite rate.
    wer = words['distance'] / word_count if word_count else (0.0 if not hyp else None)
    cer = char_errors / char_count if char_count else (0.0 if not hyp_chars else None)
    return {'wer': wer, 'cer': cer, 'referenceWordCount': word_count,
            'hypothesisWordCount': len(hyp.split()), 'referenceCharacterCount': char_count,
            'characterErrors': char_errors, 'wordEdits': words,
            'normalization': 'NFKC, Unicode casefold, punctuation to spaces, collapsed whitespace; CER excludes spaces'}


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def local_path(value, base):
    if not isinstance(value, str) or not value:
        raise ValueError('An audio/reference path must be a nonempty string')
    path = pathlib.Path(value).expanduser()
    return (path if path.is_absolute() else base / path).resolve(strict=True)


def load_reference(value, base):
    if value is None:
        return None
    if not isinstance(value, dict) or not isinstance(value.get('provenance'), str) or not value['provenance'].strip():
        raise ValueError('Every supplied reference requires a nonempty provenance description')
    path = local_path(value.get('path'), base)
    raw = path.read_bytes()
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        raise ValueError('A supplied reference must be UTF-8 text') from None
    return {'text': text, 'path': str(path),
            'sha256': hashlib.sha256(raw).hexdigest(), 'provenance': value['provenance']}


def load_manifest(path):
    document = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(document, dict):
        raise ValueError('Manifest must be a JSON object')
    variants = document.get('variants')
    if not isinstance(variants, list) or not variants:
        raise ValueError('Manifest must contain a nonempty variants array')
    runs, ids = [], set()
    for variant in variants:
        if not isinstance(variant, dict):
            raise ValueError('Every variant must be a JSON object')
        identifier = variant.get('id', '')
        if not isinstance(identifier, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', identifier):
            raise ValueError('Variant IDs must be short filesystem-safe identifiers')
        if identifier in ids:
            raise ValueError('Variant IDs must be unique')
        ids.add(identifier)
        model, profile = variant.get('model'), variant.get('profile')
        if model not in ('parakeet-v3', 'parakeet-v2') or profile not in ('current', 'multilingual'):
            raise ValueError('Each variant needs a supported model and profile')
        if profile == 'multilingual' and model != 'parakeet-v3':
            raise ValueError('The multilingual profile is supported only for Parakeet v3')
        audio = local_path(variant.get('audio'), path.parent)
        if not audio.is_file():
            raise ValueError('An audio variant is not a regular file')
        reference = load_reference(variant.get('reference', document.get('reference')), path.parent)
        runs.append({'id': identifier, 'audio': audio, 'model': model, 'profile': profile,
                     'description': variant.get('description'), 'reference': reference})
    return runs


def write_json(path, value):
    with path.open('x', encoding='utf-8') as output:
        json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write('\n')
    path.chmod(0o600)


def memory_monitor():
    # Reuse the existing macOS process-tree monitor only when explicitly enabled.
    path = pathlib.Path(__file__).resolve().parent.parent / 'notes-eval' / 'run.py'
    spec = importlib.util.spec_from_file_location('quill_notes_memory_monitor', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.monitor


def run_variant(preview, variant, folder, monitor):
    folder.mkdir(mode=0o700)
    output = folder / 'transcription.json'
    digest = sha256(variant['audio'])
    command = [str(preview), 'transcribe', str(variant['audio']), variant['model'], variant['profile'], str(output)]
    started = time.monotonic()
    memory = None
    with (folder / 'native.log').open('x') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            if monitor:
                memory = monitor(child.pid, lambda: child.poll() is not None)
            status = child.wait()
        except BaseException:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            raise
    (folder / 'native.log').chmod(0o600)
    result = {'id': variant['id'], 'model': variant['model'], 'profile': variant['profile'],
              'description': variant['description'], 'audioPath': str(variant['audio']),
              'inputSHA256': digest, 'exitCode': status,
              'wallSeconds': time.monotonic() - started, 'metrics': None,
              'reference': None, 'memory': None}
    if memory is not None:
        write_json(folder / 'memory.json', memory)
        result['memory'] = {key: value for key, value in memory.items() if key != 'samples'}
    reference = variant['reference']
    if reference is not None:
        result['reference'] = {key: value for key, value in reference.items() if key != 'text'}
    if status == 0:
        try:
            native = json.loads(output.read_text(encoding='utf-8'))
            if native['inputSHA256'] != digest or native['model'] != variant['model'] or native['profile'] != variant['profile']:
                raise ValueError('Native result provenance does not match this run')
            if not isinstance(native.get('transcript'), str):
                raise ValueError('Native output has no plain transcript')
            result.update({key: native[key] for key in ('durationSeconds', 'elapsedSeconds', 'preparationSeconds',
                                                       'transcriptionSeconds', 'melChunkContext')})
            result['wordCount'] = len(native['words'])
            if reference is not None:
                result['metrics'] = error_rates(reference['text'], native['transcript'])
            else:
                result['metricsUnavailableReason'] = 'No reference supplied; accuracy is not measured.'
        except (OSError, ValueError, KeyError, TypeError):
            result['validationError'] = 'Native output was missing, invalid, or inconsistent with run provenance.'
    write_json(folder / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview', type=pathlib.Path, required=True)
    parser.add_argument('--manifest', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True, help='New output directory; existing paths are rejected')
    parser.add_argument('--monitor-memory', action='store_true', help='Sample macOS process-tree RSS/physical footprint')
    args = parser.parse_args()
    try:
        preview = args.preview.expanduser().resolve(strict=True)
        manifest = args.manifest.expanduser().resolve(strict=True)
        if not preview.is_file():
            raise ValueError('The preview executable is not a regular file')
        variants = load_manifest(manifest)
        monitor = memory_monitor() if args.monitor_memory else None
        args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except (OSError, ValueError, TypeError) as error:
        parser.error(str(error))
    metadata = {'schemaVersion': 1, 'manifestPath': str(manifest), 'manifestSHA256': sha256(manifest),
                'previewPath': str(preview), 'previewSHA256': sha256(preview),
                'variantOrder': [variant['id'] for variant in variants], 'serial': True}
    write_json(args.output / 'evaluation.json', metadata)
    results = []
    for variant in variants:
        result = run_variant(preview, variant, args.output / variant['id'], monitor)
        results.append(result)
        metrics = result['metrics']
        print(json.dumps({'id': result['id'], 'exitCode': result['exitCode'],
                          'wallSeconds': result['wallSeconds'], 'wer': metrics['wer'] if metrics else None,
                          'cer': metrics['cer'] if metrics else None,
                          'validationError': result.get('validationError')}, allow_nan=False), flush=True)
    write_json(args.output / 'runs.json', results)
    if any(result['exitCode'] != 0 or 'validationError' in result for result in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
