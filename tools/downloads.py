"""Pinned downloads and extraction into new private build directories."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

MAX_DOWNLOAD = 1024 * 1024 * 1024
MAX_EXTRACT = 2 * MAX_DOWNLOAD


class DownloadFailed(RuntimeError):
    """A network failure, with the file name and URL so callers can name the site."""

    def __init__(self, name, url, error):
        super().__init__(f'download failed for {name}: {error}')
        self.name, self.url = name, url


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def fetch(cache: Path, name: str, url: str, sha256: str) -> Path:
    """Verify every cached use and publish a download only after verification."""
    if (not name or Path(name).name != name or name in ('.', '..') or '\\' in name
            or ':' in name or any(ord(c) < 32 for c in name)):
        raise ValueError('download name must be a single filename')
    if not re.fullmatch(r'[0-9a-f]{64}', sha256):
        raise ValueError('invalid SHA256')
    if not url.startswith('https://'):
        raise ValueError('downloads require HTTPS')
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / name
    if target.is_symlink():
        raise ValueError(f'cache symlink is unsupported: {target}')
    if target.exists():
        if not target.is_file() or digest(target) != sha256:
            raise ValueError(f'cached checksum mismatch: {target}; remove this cache file and retry')
        return target
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.' + name + '-', dir=cache, delete=False) as out:
            temporary = Path(out.name)
            request = urllib.request.Request(url, headers={'User-Agent': 'NFSIV-build/1'})
            started = time.monotonic()
            with urllib.request.urlopen(request, timeout=60) as response:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_DOWNLOAD:
                        raise ValueError(f'download exceeds {MAX_DOWNLOAD} bytes: {name}')
                    if time.monotonic() - started > 600:
                        raise ValueError(f'download exceeded ten minutes: {name}')
                    out.write(chunk)
        if digest(temporary) != sha256:
            raise ValueError(f'download checksum mismatch: {name}')
        os.replace(temporary, target)
        return target
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise DownloadFailed(name, url, error) from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def safe_path(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or '..' in path.parts or '\\' in name
            or ':' in name or any(ord(c) < 32 for c in name)):
        raise ValueError(f'unsafe archive path: {name!r}')
    return path


def extract_tar(archive, destination, include=None):
    """Extract regular files/directories only; reject links before any output."""
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        for member in members:
            safe_path(member.name)
        if include is not None:
            members = [m for m in members if any(m.name == prefix or m.name.startswith(prefix.rstrip('/') + '/')
                                                for prefix in include)]
        paths, total = set(), 0
        for member in members:
            path = safe_path(member.name)
            key = str(path).casefold()
            if key in paths or not (member.isfile() or member.isdir()):
                raise ValueError(f'unsupported archive entry or duplicate path: {member.name}')
            paths.add(key)
            total += member.size
            if total > MAX_EXTRACT:
                raise ValueError('archive is too large')
        destination.mkdir(parents=True)
        try:
            for member in members:
                target = destination.joinpath(*safe_path(member.name).parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as source, target.open('xb') as out:
                        shutil.copyfileobj(source, out)
                    target.chmod(0o755 if member.mode & 0o111 else 0o644)
        except BaseException:
            shutil.rmtree(destination)
            raise


def extract_7z(archive, destination, extractor, include=None):
    """Validate 7-Zip's listing before extraction, then reject output links."""
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    result = subprocess.run([str(extractor), 'l', '-slt', '-ba', str(archive)],
                            check=True, capture_output=True, text=True, timeout=120)
    prefixes = None if include is None else tuple(str(safe_path(prefix)).casefold() for prefix in include)
    paths, names, total = set(), [], 0
    for block in re.split(r'\r?\n\r?\n', result.stdout.strip()):
        fields = dict(line.split(' = ', 1) for line in block.splitlines() if ' = ' in line)
        if 'Path' not in fields:
            continue
        path = safe_path(fields['Path'])
        key = str(path).casefold()
        if prefixes is not None and not any(key == prefix or key.startswith(prefix + '/') for prefix in prefixes):
            continue
        if (key in paths or fields.get('Symbolic Link') or fields.get('Hard Link')
                or fields.get('Attributes', '').split(' ')[-1].startswith('l')
                or fields.get('Anti') == '+'):
            raise ValueError(f'unsupported archive link or duplicate path: {path}')
        paths.add(key)
        size = int(fields.get('Size', '0'))
        if size < 0:
            raise ValueError(f'invalid archive file size: {path}')
        total += size
        if total > MAX_EXTRACT:
            raise ValueError('archive is too large')
        attributes = fields.get('Attributes', '')
        if fields.get('Folder') != '+' and not attributes.startswith('D') and not attributes.split(' ')[-1].startswith('d'):
            names.append(fields['Path'])
    if not paths or (include is not None and not names):
        raise ValueError('empty or unreadable archive')
    destination.mkdir(parents=True)
    try:
        command = [str(extractor), 'x', '-y', '-bd', '-bso0', '-bsp0', '-spd', '-o' + str(destination), '--', str(archive)]
        # Exact listed files avoid extracting unrelated installer payloads or interpreting wildcards.
        if include is not None:
            command.extend(names)
        subprocess.run(command, check=True, timeout=300)
        for path in destination.rglob('*'):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError(f'unsupported extracted file: {path}')
            if path.is_file() and path.relative_to(destination).as_posix().casefold() not in paths:
                raise ValueError(f'unexpected extracted file: {path}')
    except BaseException:
        shutil.rmtree(destination)
        raise
