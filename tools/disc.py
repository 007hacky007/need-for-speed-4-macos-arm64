#!/usr/bin/env python3
"""Read ISO9660/Joliet from BIN/CUE, MODE1/2352 MDF or a 2048-byte ISO.

Usage: python3 tools/disc.py IMAGE NEW_DIRECTORY
The image is read-only and the destination must not already exist.
"""
import argparse
import json
import re
import shutil
import struct
from pathlib import Path, PurePosixPath
from typing import NamedTuple


class DiscError(ValueError):
    pass


def cue_image(path):
    """Resolve the supported single-track CUE without guessing a track layout."""
    lines = [line.strip() for line in path.read_text(encoding='utf-8-sig').splitlines()
             if line.strip() and not line.lstrip().upper().startswith('REM ')]
    if len(lines) != 3:
        raise DiscError('CUE requires one FILE, one MODE1/2352 TRACK and INDEX 01 00:00:00')
    match = re.fullmatch(r'FILE\s+"([^"\x00]+)"\s+BINARY', lines[0], re.I)
    if not match or not re.fullmatch(r'TRACK\s+0?1\s+MODE1/2352', lines[1], re.I) or not re.fullmatch(r'INDEX\s+0?1\s+00:00:00', lines[2], re.I):
        raise DiscError('unsupported CUE layout; expected one MODE1/2352 track at 00:00:00')
    name = match[1]
    if name in ('.', '..') or any(c in name for c in '/\\:') or any(ord(c) < 32 for c in name):
        raise DiscError('CUE BIN must be a filename beside the CUE')
    image = path.parent / name
    if image.is_symlink() or not image.is_file():
        raise DiscError('CUE BIN must be a regular file beside the CUE')
    return image


class Entry(NamedTuple):
    path: PurePosixPath
    extent: int
    size: int


class Disc:
    def __init__(self, path):
        self.path = Path(path)
        is_cue = self.path.suffix.lower() == '.cue'
        if is_cue:
            self.path = cue_image(self.path)
        self.file = self.path.open('rb')
        try:
            size = self.path.stat().st_size
            self.file.seek(16 * 2352)
            raw = self.file.read(24)
            if raw[:12] == b'\x00' + b'\xff' * 10 + b'\x00':
                self.stride, self.offset = 2352, 16
            else:
                self.stride, self.offset = 2048, 0
            if is_cue and self.stride != 2352:
                raise DiscError('CUE declares MODE1/2352 but BIN is not raw MODE1 data')
            if size % self.stride:
                raise DiscError(f'truncated image: {size} bytes, sector size {self.stride}')
            self.sectors = size // self.stride
            self.root = None
            self.joliet = False
            self.label = ''
            for lba in range(16, min(self.sectors, 80)):
                data = self.read_extent(lba, 2048)
                if data[1:7] != b'CD001\x01':
                    raise DiscError(f'invalid ISO descriptor at sector {lba}')
                kind = data[0]
                if kind == 255:
                    break
                is_joliet = kind == 2 and data[88:91] in (b'%/@', b'%/C', b'%/E')
                if kind == 1 and self.root is None or is_joliet:
                    self.joliet = is_joliet
                    self.root = data[156:190]
                    self.label = data[40:72].decode('utf-16-be' if is_joliet else 'ascii').strip(' \x00')
                    if data[128:132] != b'\x00\x08\x08\x00':
                        raise DiscError('only 2048-byte ISO logical blocks are supported')
            else:
                raise DiscError('ISO volume terminator not found')
            if self.root is None:
                raise DiscError('ISO primary volume not found')
        except BaseException:
            self.file.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.file.close()

    def _bounds(self, extent, size):
        if extent < 0 or size < 0 or extent + (size + 2047) // 2048 > self.sectors:
            raise DiscError(f'extent outside image: sector {extent}, {size} bytes')

    def read_extent(self, extent, size):
        self._bounds(extent, size)
        self.file.seek(extent * self.stride)
        count = (size + 2047) // 2048
        data = self.file.read(count * self.stride)
        if len(data) != count * self.stride:
            raise DiscError(f'truncated extent at sector {extent}')
        if self.stride == 2048:
            return data[:size]
        result = bytearray()
        for i in range(count):
            start = i * self.stride
            sector = data[start:start + self.stride]
            if sector[:12] != b'\x00' + b'\xff' * 10 + b'\x00' or sector[15] != 1:
                raise DiscError(f'not a MODE1/2352 data sector: {extent + i}')
            result.extend(sector[16:2064])
        return bytes(result[:size])

    @staticmethod
    def _location(record):
        extent = struct.unpack_from('<I', record, 2)[0]
        size = struct.unpack_from('<I', record, 10)[0]
        if extent != struct.unpack_from('>I', record, 6)[0] or size != struct.unpack_from('>I', record, 14)[0]:
            raise DiscError('inconsistent ISO extent or size')
        if record[1] or record[26] or record[27] or record[25] & 128:
            raise DiscError('extended, interleaved or multi-extent file is unsupported')
        return extent, size

    def entries(self):
        paths = set()
        directories = set()

        def walk(record, parent, depth):
            if depth > 32:
                raise DiscError('directory nesting exceeds 32 levels')
            location = self._location(record)
            if location in directories:
                raise DiscError(f'directory cycle or alias at {parent}')
            directories.add(location)
            data = self.read_extent(*location)
            offset = 0
            while offset < len(data):
                length = data[offset]
                if not length:
                    offset = (offset // 2048 + 1) * 2048
                    continue
                if length < 34 or offset + length > len(data) or offset % 2048 + length > 2048:
                    raise DiscError(f'invalid directory record at {parent}:{offset}')
                child = data[offset:offset + length]
                offset += length
                name_length = child[32]
                if not name_length or 33 + name_length > length:
                    raise DiscError(f'invalid filename record at {parent}')
                ident = child[33:33 + name_length]
                if ident in (b'\x00', b'\x01'):
                    continue
                try:
                    name = ident.decode('utf-16-be' if self.joliet else 'ascii').removesuffix(';1')
                except UnicodeError as e:
                    raise DiscError(f'invalid filename encoding at {parent}') from e
                if name in ('', '.', '..') or any(c in name for c in '/\\\x00:') or any(ord(c) < 32 for c in name):
                    raise DiscError(f'unsafe filename {name!r}')
                path = parent / name
                key = str(path).casefold()
                if key in paths:
                    raise DiscError(f'duplicate case-insensitive path: {path}')
                paths.add(key)
                extent, size = self._location(child)
                self._bounds(extent, size)
                if child[25] & 2:
                    yield from walk(child, path, depth + 1)
                else:
                    yield Entry(path, extent, size)

        yield from walk(self.root, PurePosixPath(), 0)

    def extract(self, destination):
        destination = Path(destination)
        if destination.exists() or destination.is_symlink():
            raise FileExistsError(f'destination already exists: {destination}')
        entries = list(self.entries())
        destination.mkdir(parents=True)
        try:
            for entry in entries:
                target = destination.joinpath(*entry.path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as out:
                    left, extent = entry.size, entry.extent
                    while left:
                        size = min(left, 2048 * 256)
                        out.write(self.read_extent(extent, size))
                        extent += (size + 2047) // 2048
                        left -= size
        except BaseException:
            shutil.rmtree(destination)
            raise
        return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    with Disc(args.image) as disc:
        entries = disc.extract(args.destination)
        print(json.dumps({'volume': disc.label, 'joliet': disc.joliet,
                          'files': len(entries), 'bytes': sum(e.size for e in entries),
                          'destination': str(args.destination)}, indent=2))


if __name__ == '__main__':
    main()
