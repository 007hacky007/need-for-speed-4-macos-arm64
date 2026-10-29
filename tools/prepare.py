#!/usr/bin/env python3
"""Prepare a verified local NFS IV executable and sound module for ARM64 translation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

import pefile

ROOT = Path(__file__).resolve().parents[1]
GAME_SHA = '17a0f96c3bcfb94fc72d31a429ef56e14ec028e4a6ed1f692cdd8efc0b762980'
SOUND_BASE = 0x1100000
SOUND_SHA = 'b23b61b85b3ad6b1d3f449e13a882585c254f271367bce5f932402163c9a358b'


def section_extent(section):
    return section.Misc_VirtualSize or section.SizeOfRawData


def checked_bytes(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('unsupported input checksum')
    return data


def align(value, boundary):
    return (value + boundary - 1) & -boundary


def link_modules(exe_data, sound_data):
    """Combine privately supplied modules; output stays in ignored build storage."""
    game = pefile.PE(data=checked_bytes(exe_data, GAME_SHA))
    sound = pefile.PE(data=checked_bytes(sound_data, SOUND_SHA))
    if sound.FILE_HEADER.Machine != 0x14c or not hasattr(sound, 'DIRECTORY_ENTRY_BASERELOC'):
        raise ValueError('unsupported sound module')
    sound.relocate_image(SOUND_BASE)
    base = game.OPTIONAL_HEADER.ImageBase
    modules = [(game, 0), (sound, SOUND_BASE - base)]
    imports, relocs, seeds, sections, exports = [], [], {base + game.OPTIONAL_HEADER.AddressOfEntryPoint}, [], []
    for pe, delta in modules:
        for module in pe.DIRECTORY_ENTRY_IMPORT:
            for symbol in module.imports:
                imports.append((symbol.address, module.dll.decode(), symbol.name.decode() if symbol.name else f'#{symbol.ordinal}'))
        relocs.extend(pe.OPTIONAL_HEADER.ImageBase + e.rva
                      for b in pe.DIRECTORY_ENTRY_BASERELOC for e in b.entries if e.type == 3)
        for e in getattr(getattr(pe, 'DIRECTORY_ENTRY_EXPORT', None), 'symbols', []):
            if e.forwarder:
                raise ValueError('forwarded sound exports are unsupported')
            address = pe.OPTIONAL_HEADER.ImageBase + e.address
            seeds.add(address)
            exports.append((e.name.decode() if e.name else f'#{e.ordinal}', address))
        for s in pe.sections:
            extent = section_extent(s)
            if not extent:
                continue
            data = s.get_data() if s.PointerToRawData else b''
            if data and s.PointerToRawData + len(data) > len(pe.__data__):
                raise ValueError('section extends outside input file')
            sections.append((s.Name, s.VirtualAddress + delta, extent, data, s.Characteristics))

    # Keep imports at their original guest IAT slots; concatenate descriptors only.
    groups = []
    for pe, _ in modules:
        for module in pe.DIRECTORY_ENTRY_IMPORT:
            groups.append((module.dll.decode(), [(s.address - base, s.name.decode() if s.name else s.ordinal) for s in module.imports]))
    imports_rva = align(max(rva + extent for _, rva, extent, _, _ in sections), 4096)
    payload = bytearray((len(groups) + 1) * 20)
    for index, (dll, symbols) in enumerate(groups):
        name_rva = imports_rva + len(payload)
        payload.extend(dll.encode() + b'\0')
        names = []
        for iat, name in symbols:
            if isinstance(name, int):
                names.append(0x80000000 | name)
            else:
                payload.extend(bytes(-len(payload) % 2))
                names.append(imports_rva + len(payload))
                payload.extend(b'\0\0' + name.encode() + b'\0')
        payload.extend(bytes(-len(payload) % 4))
        int_rva = imports_rva + len(payload)
        payload.extend(struct.pack('<' + 'I' * (len(names) + 1), *names, 0))
        struct.pack_into('<IIIII', payload, index * 20, int_rva, 0, 0, name_rva, symbols[0][0])
    sections.append((b'.hostimp', imports_rva, len(payload), bytes(payload), 0xc0000040))
    headers = bytearray(exe_data[:4096])
    nt = struct.unpack_from('<I', headers, 0x3c)[0]
    optional = nt + 24
    table = optional + game.FILE_HEADER.SizeOfOptionalHeader
    if table + len(sections) * 40 > 4096:
        raise ValueError('too many linked sections')
    struct.pack_into('<H', headers, nt + 6, len(sections))
    struct.pack_into('<I', headers, optional + 56, align(imports_rva + len(payload), 4096))
    struct.pack_into('<I', headers, optional + 60, 4096)
    # Relocation and export metadata are consumed at preparation time.
    struct.pack_into('<II', headers, optional + 96, 0, 0)
    struct.pack_into('<II', headers, optional + 96 + 8, imports_rva, (len(groups) + 1) * 20)
    struct.pack_into('<II', headers, optional + 96 + 5 * 8, 0, 0)
    output = headers
    for index, (name, rva, extent, data, flags) in enumerate(sections):
        offset = len(output) if data else 0
        raw = align(len(data), 512)
        output.extend(data + bytes(raw - len(data)))
        struct.pack_into('<8sIIIIIIHHI', output, table + 40 * index,
                         name, extent, rva, raw, offset, 0, 0, 0, 0, flags)
    return bytes(output), imports, relocs, seeds, exports


def prepare(folder):
    folder = Path(folder)
    linked, imports, relocs, seeds, exports = link_modules(
        (folder / 'nfs4.exe').read_bytes(), (folder / 'eacsnd.dll').read_bytes())
    out, gen = ROOT / 'out', ROOT / 'gen/all'
    out.mkdir(exist_ok=True)
    gen.mkdir(parents=True, exist_ok=True)
    image = out / 'linked.exe'
    image.write_bytes(linked)
    pe = pefile.PE(data=linked)
    base = pe.OPTIONAL_HEADER.ImageBase
    ranges = [(base + s.VirtualAddress, base + s.VirtualAddress + section_extent(s))
              for s in pe.sections if s.Characteristics & 0x20000000]
    # DLL exports and relocation pointers seed functions beyond direct calls.
    (out / 'relocs.txt').write_text(''.join(f'{a:08x}\n' for a in sorted(relocs)))
    (out / 'seeds.txt').write_text(''.join(f'{a:08x}\n' for a in sorted(seeds)))
    counts = json.loads((ROOT / 'tools/win32_args.json').read_text())
    counts.update({'CreateProcessA': 10, 'GetCommProperties': 2, 'GetCommModemStatus': 2,
                   'WaitForMultipleObjectsEx': 5, 'PulseEvent': 1, 'OpenMutexA': 3,
                   'GetLogicalDriveStringsA': 2, 'GetWindowDC': 1, 'GetKeyboardType': 1,
                   'GetKeyState': 1, 'CharUpperA': 1, 'FindWindowA': 2, 'CallNextHookEx': 4,
                   'SetWindowsHookExA': 4, 'UnhookWindowsHookEx': 1, 'SendNotifyMessageA': 4,
                   'RegisterClassA': 1, 'SystemParametersInfoA': 4, 'keybd_event': 4,
                   'DirectDrawEnumerateA': 2, 'DirectInputCreateA': 4, '__WSAFDIsSet': 2,
                   'GetFileVersionInfoA': 4, 'GetFileVersionInfoSizeA': 2, 'VerQueryValueA': 4,
                   'GetPrivateProfileIntA': 4, 'GetPrivateProfileStringA': 6,
                   'GetPrivateProfileSectionA': 4, 'SetEnvironmentVariableW': 2,
                   'SetErrorMode': 1, 'DirectSoundCreate': 3, '#1': 3,
                   'CharUpperBuffA': 2, 'CompareFileTime': 2, 'DdeClientTransaction': 8,
                   'DdeConnect': 4, 'DdeCreateStringHandleA': 3, 'DdeGetLastError': 1,
                   'DdeInitializeA': 4, 'DdeQueryStringA': 5, 'DdeUninitialize': 1,
                   'GetConsoleMode': 2, 'ReadConsoleInputA': 4, 'SetConsoleMode': 2,
                   'SwapMouseButton': 1, 'WinExec': 2, 'WriteConsoleA': 5,
                   '_lclose': 1, '_lopen': 2, 'mciSendStringA': 4,
                   'mixerGetControlDetailsA': 3, 'mixerGetLineControlsA': 3,
                   'mixerGetLineInfoA': 3, 'mixerGetNumDevs': 0, 'mixerSetControlDetails': 3})
    missing = sorted({n for _, _, n in imports if n not in counts})
    if missing:
        raise ValueError('unknown import calling conventions: ' + ', '.join(missing))
    header = '''#ifndef NFSIV_IMAGE_H
#define NFSIV_IMAGE_H
#include <stdint.h>
typedef struct { uint32_t address, offset, size; } ImageSection;
typedef struct { uint32_t iat; const char *dll, *name; int nargs; } Import;
typedef struct { const char *name; uint32_t address; } GuestExport;
extern const ImageSection nfsiv_sections[];
extern const uint32_t nfsiv_section_count;
extern const Import nfsiv_imports[];
extern const uint32_t nfsiv_import_count;
extern const GuestExport nfsiv_sound_exports[];
extern const uint32_t nfsiv_sound_export_count;
'''
    values = {'IMAGE_BASE': base, 'IMAGE_SIZE': pe.OPTIONAL_HEADER.SizeOfImage,
              'IMAGE_ENTRY': base + pe.OPTIONAL_HEADER.AddressOfEntryPoint,
              'IMAGE_FILE_SIZE': len(linked), 'DISPATCH_TEXT_BASE': min(lo for lo, hi in ranges),
              'DISPATCH_TEXT_SIZE': max(hi for lo, hi in ranges) - min(lo for lo, hi in ranges),
              'SOUND_MODULE': SOUND_BASE}
    header += ''.join(f'#define {name} 0x{value:x}u\n' for name, value in values.items())
    header += '#define IMAGE_SHA256 "' + hashlib.sha256(linked).hexdigest() + '"\n#endif\n'
    (gen / 'image.h').write_text(header)
    source = '#include "image.h"\n'
    source += f'const uint32_t nfsiv_section_count = {len(pe.sections)};\nconst ImageSection nfsiv_sections[] = {{\n'
    for s in pe.sections:
        size = min(s.SizeOfRawData, section_extent(s)) if s.PointerToRawData else 0
        source += f'{{0x{base+s.VirtualAddress:x}u,{s.PointerToRawData}u,{size}u}},\n'
    source += '};\n'
    source += f'const uint32_t nfsiv_import_count = {len(imports)};\nconst Import nfsiv_imports[] = {{\n'
    for address, dll, name in imports:
        source += f'{{0x{address:x}u,{json.dumps(dll)},{json.dumps(name)},{counts[name]}}},\n'
    source += '};\n'
    source += f'const uint32_t nfsiv_sound_export_count = {len(exports)};\nconst GuestExport nfsiv_sound_exports[] = {{\n'
    source += ''.join(f'{{{json.dumps(n)},0x{a:x}u}},\n' for n, a in exports) + '};\n'
    (gen / 'image.c').write_text(source)
    (out / 'image.json').write_text(json.dumps({'sha256': hashlib.sha256(linked).hexdigest(),
                                              'imports': len(imports), 'exports': exports,
                                              'ranges': ranges}, indent=2) + '\n')
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game_folder', type=Path)
    parser.add_argument('--metadata-only', action='store_true')
    args = parser.parse_args()
    os.chdir(ROOT)
    image = prepare(args.game_folder.resolve())
    if not args.metadata_only:
        subprocess.run([sys.executable, 'tools/genall.py', str(image), '64'], check=True,
                       env=dict(os.environ, SEEDS='out/seeds.txt', X87PC='1', WATCH='1',
                                     HOOKS='46d781,46de06,4f73d6'))


if __name__ == '__main__':
    main()
