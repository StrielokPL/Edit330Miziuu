"""Build a file overlay without publishing the unchanged original mod. Python 3.10+."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import zipfile
from pathlib import Path, PurePosixPath
from xml.etree import ElementTree as ET

PROFILES = {
    'c330': {'Scripts', 'Textures', 'Wheels', 'prefabs', 'sounds'},
    'c355360': {'Scripts', 'Store', 'frontloaders', 'sounds', 'textures', 'wheels', 'Economy'},
}
ROOT_EXTENSIONS = {'.xml', '.i3d', '.shapes', '.dds'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def safe_path(value):
    p = PurePosixPath(value)
    if (not value or value != p.as_posix() or p.is_absolute() or '\\' in value
            or any(part in {'', '.', '..'} or ':' in part for part in value.split('/'))):
        raise ValueError(f'Unsafe member path: {value!r}')
    return value


def zip_index(archive):
    result = {}
    folded = set()
    for info in archive.infolist():
        if info.is_dir():
            continue
        name = safe_path(info.filename)
        if name.casefold() in folded:
            raise ValueError(f'Duplicate/case-colliding ZIP member: {name}')
        folded.add(name.casefold())
        result[name] = {'sha256': digest(archive.read(info)), 'size': info.file_size}
    return result


def source_files(root, profile):
    if profile not in PROFILES:
        raise ValueError('Unknown runtime profile')
    result = {}
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if not (rel.parts[0] in PROFILES[profile]
                or (len(rel.parts) == 1 and path.suffix.lower() in ROOT_EXTENSIONS)):
            continue
        if path.is_symlink():
            raise ValueError(f'Runtime symlink is not supported: {rel}')
        if path.is_file():
            name = safe_path(rel.as_posix())
            if any(n.casefold() == name.casefold() for n in result):
                raise ValueError(f'Case-colliding source path: {name}')
            result[name] = path
    if 'modDesc.xml' not in result:
        raise ValueError('Source has no root modDesc.xml')
    return result


def content_digest(index):
    # Canonical JSON, independent of ZIP compression, timestamps and file order.
    records = [{'path': name, **index[name]} for name in sorted(index)]
    return digest(json.dumps(records, ensure_ascii=False, separators=(',', ':')).encode())


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def verify(repo, base, expected_source=None):
    manifest = json.loads((repo / 'updater.json').read_text(encoding='utf-8'))
    if manifest['schemaVersion'] != 1 or manifest['packageType'] != 'file-overlay':
        raise ValueError('Unsupported overlay schema')
    if file_digest(base) != manifest['baseMod']['sha256']:
        raise ValueError('Wrong original ZIP: SHA-256 does not match')
    with zipfile.ZipFile(base) as z:
        index = zip_index(z)
    if content_digest(index) != manifest['baseMod']['contentSha256']:
        raise ValueError('Original content index mismatch')
    listed = set()
    for entry in manifest['files']:
        name = safe_path(entry['path'])
        if name in listed:
            raise ValueError('Duplicate payload path')
        listed.add(name)
        old = index.get(name)
        if entry['action'] not in {'add', 'replace'}:
            raise ValueError('Unknown overlay action')
        if (entry['action'] == 'add') != (old is None):
            raise ValueError(f'Incorrect add/replace action for {name}')
        if old and old['sha256'] != entry['baseSha256']:
            raise ValueError(f'Unexpected base content: {name}')
        p = repo / 'files' / name
        if p.is_symlink() or file_digest(p) != entry['sha256'] or p.stat().st_size != entry['size']:
            raise ValueError(f'Payload mismatch: {name}')
        if old and old['sha256'] == entry['sha256']:
            raise ValueError(f'Unchanged original accidentally included: {name}')
        index[name] = {'sha256': entry['sha256'], 'size': entry['size']}
    actual = {p.relative_to(repo / 'files').as_posix()
              for p in (repo / 'files').rglob('*') if p.is_file()}
    if actual != listed:
        raise ValueError('Unlisted or missing payload files')
    deleted = set()
    for entry in manifest['delete']:
        name = safe_path(entry['path'])
        if name in deleted or name in listed or name not in index:
            raise ValueError('Invalid deletion record')
        deleted.add(name)
        if index[name]['sha256'] != entry['baseSha256']:
            raise ValueError('Deletion base hash mismatch')
        del index[name]
    if (content_digest(index) != manifest['result']['contentSha256']
            or len(index) != manifest['result']['fileCount']):
        raise ValueError('Reconstructed content differs from the expected result')
    if expected_source is not None:
        paths = source_files(expected_source, manifest['source']['runtimeProfile'])
        expected = {n: {'sha256': file_digest(p), 'size': p.stat().st_size}
                    for n, p in paths.items()}
        if index != expected:
            raise ValueError('Reconstruction does not exactly match working source')
    return {'verified': True, 'reconstructedFiles': len(index),
            'contentSha256': content_digest(index), 'unchangedFilesInPayload': 0}


def build(repo, source, base, replace=False):
    cfg = json.loads((repo / 'edit-config.json').read_text(encoding='utf-8'))
    expected_hash = cfg['baseMod'].get('sha256')
    if expected_hash and file_digest(base) != expected_hash:
        raise ValueError('Wrong original ZIP: it does not match the configured SHA-256')
    with zipfile.ZipFile(base) as z:
        original = zip_index(z)
        base_xml_version = ET.fromstring(z.read('modDesc.xml')).findtext('version').strip()
    if base_xml_version != cfg['baseMod']['modDescVersion']:
        raise ValueError(f'Wrong base XML version: {base_xml_version}')
    paths = source_files(source, cfg['runtimeProfile'])
    target = {n: {'sha256': file_digest(p), 'size': p.stat().st_size} for n, p in paths.items()}
    # Reject case-only renames: they have ambiguous behavior on Windows filesystems.
    all_names = set(original) | set(target)
    if len({n.casefold() for n in all_names}) != len(all_names):
        raise ValueError('Case-only renames are not supported')
    edit_version = ET.parse(paths['modDesc.xml']).findtext('version').strip()
    commit = git(source, 'rev-parse', 'HEAD')
    if git(source, 'status', '--porcelain'):
        raise ValueError('Working source must be committed before making an overlay')
    payload = repo / 'files'
    if payload.exists():
        if not replace:
            raise ValueError('files/ exists; use --replace to regenerate this generated directory')
        if payload.is_symlink():
            raise ValueError('files/ must not be a symlink')
        shutil.rmtree(payload)
    payload.mkdir()
    files = []
    for name in sorted(target):
        if original.get(name) == target[name]:
            continue
        destination = payload / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(paths[name], destination)
        entry = {'path': name, 'action': 'replace' if name in original else 'add', **target[name]}
        if name in original:
            entry['baseSha256'] = original[name]['sha256']
        files.append(entry)
    deleted = [{'path': n, 'baseSha256': original[n]['sha256']}
               for n in sorted(set(original) - set(target))]
    manifest = {
        'schemaVersion': 1, 'packageType': 'file-overlay', 'id': cfg['id'],
        'version': edit_version, 'archiveName': cfg['archiveName'],
        'compatibilityPolicy': 'warn-and-confirm',
        'baseMod': {**cfg['baseMod'], 'archiveName': cfg['archiveName'],
                    'sha256': file_digest(base), 'contentSha256': content_digest(original),
                    'fileCount': len(original)},
        'source': {'repository': cfg['sourceRepository'], 'commit': commit,
                   'runtimeProfile': cfg['runtimeProfile']},
        'files': files, 'delete': deleted,
        'result': {'modDescVersion': edit_version, 'fileCount': len(target),
                   'contentSha256': content_digest(target)},
        'validation': {'reconstruction': 'exact-source-match', 'gameTested': False},
    }
    save_json(repo / 'updater.json', manifest)
    save_json(repo / 'delete.json', {'files': [e['path'] for e in deleted]})
    validation = verify(repo, base, source)
    summary = {
        'editVersion': edit_version, 'baseKingmodsVersion': cfg['baseMod']['version'],
        'baseModDescVersion': base_xml_version, 'sourceCommit': commit,
        'baseFiles': len(original), 'resultFiles': len(target),
        'unchanged': sum(original.get(n) == target[n] for n in target),
        'modified': sum(e['action'] == 'replace' for e in files),
        'added': sum(e['action'] == 'add' for e in files), 'deleted': len(deleted),
        'payloadBytes': sum(e['size'] for e in files), **validation,
        'gameTested': False,
    }
    save_json(repo / 'comparison.json', summary)
    dist = repo / 'dist'
    dist.mkdir(exist_ok=True)
    filename = f"{cfg['id']}-{edit_version}.zip"
    if not re.fullmatch(r'[A-Za-z0-9._-]+\.zip', filename):
        raise ValueError('Unsafe package filename')
    with zipfile.ZipFile(dist / filename, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name in ['updater.json', 'delete.json']:
            z.write(repo / name, name)
        for entry in files:
            z.write(payload / entry['path'], 'files/' + entry['path'])
    with zipfile.ZipFile(dist / filename) as z:
        if z.testzip() is not None:
            raise ValueError('Damaged edit archive')
        if set(z.namelist()) != {'updater.json', 'delete.json'} | {'files/' + n for n in listed_paths(files)}:
            raise ValueError('Unexpected edit archive contents')
    (dist / 'SHA256SUMS.txt').write_text(file_digest(dist / filename) + '  ' + filename + '\n',
                                      encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def listed_paths(files):
    return [e['path'] for e in files]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['build', 'verify'])
    p.add_argument('--base', required=True, type=Path, help='Original ZIP, kept outside this repo')
    p.add_argument('--source', type=Path, help='Clean working mod checkout')
    p.add_argument('--repo', type=Path, default=Path(__file__).resolve().parent.parent)
    p.add_argument('--replace', action='store_true', help='Regenerate only files/ and generated metadata')
    args = p.parse_args()
    if args.command == 'build':
        if args.source is None:
            p.error('--source is required for build')
        build(args.repo.resolve(), args.source.resolve(), args.base.resolve(), args.replace)
    else:
        print(json.dumps(verify(args.repo.resolve(), args.base.resolve(),
                                args.source.resolve() if args.source else None), indent=2))


if __name__ == '__main__':
    main()
