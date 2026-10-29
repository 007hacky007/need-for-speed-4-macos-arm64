import struct
import tempfile
import unittest
from pathlib import Path

from tools.disc import Disc, DiscError


def record(name, extent, size, directory=False):
    ident = name if isinstance(name, bytes) else name.encode('utf-16-be')
    n = 33 + len(ident) + (len(ident) % 2 == 0)
    b = bytearray(n)
    b[0] = n
    struct.pack_into('<I', b, 2, extent)
    struct.pack_into('>I', b, 6, extent)
    struct.pack_into('<I', b, 10, size)
    struct.pack_into('>I', b, 14, size)
    b[25] = 2 if directory else 0
    b[28:32] = b'\x01\x00\x00\x01'
    b[32] = len(ident)
    b[33:33 + len(ident)] = ident
    return b


def image(name='Simulation', raw=True):
    sectors = [bytearray(2048) for _ in range(24)]
    for index, kind in ((16, 1), (17, 2), (18, 255)):
        sectors[index][:7] = bytes([kind]) + b'CD001\x01'
    sectors[16][128:132] = b'\x00\x08\x08\x00'
    sectors[16][156:190] = record(b'\x00', 20, 2048, True)
    sectors[17][88:91] = b'%/E'
    sectors[17][128:132] = b'\x00\x08\x08\x00'
    sectors[17][156:190] = record(b'\x00', 20, 2048, True)
    sectors[20][:34] = record(b'\x00', 20, 2048, True)
    entry = record(name, 21, 2048, True)
    sectors[20][34:34 + len(entry)] = entry
    entry = record('cop356_german.crp;1', 22, 5)
    sectors[21][:len(entry)] = entry
    sectors[22][:5] = b'asset'
    if not raw:
        return b''.join(sectors)
    return b''.join(b'\x00' + b'\xff' * 10 + b'\x00' + b'\x00\x02\x00\x01'
                    + s + bytes(288) for s in sectors)


class DiscTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def open_image(self, data):
        p = self.root / 'disc.mdf'
        p.write_bytes(data)
        return Disc(p)

    def cue(self, text='FILE "disc.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'):
        (self.root / 'disc.bin').write_bytes(image())
        path = self.root / 'disc.cue'
        path.write_text(text)
        return path

    def test_cue_extracts_its_named_bin(self):
        with Disc(self.cue()) as disc:
            disc.extract(self.root / 'game')
        self.assertEqual((self.root / 'game/Simulation/cop356_german.crp').read_bytes(), b'asset')

    def test_clonecd_cue_accepts_single_digit_track_and_index(self):
        cue = self.cue('FILE "disc.bin" BINARY\nTRACK 1 MODE1/2352\nINDEX 1 00:00:00\n')
        with Disc(cue) as disc:
            disc.extract(self.root / 'game')
        self.assertEqual((self.root / 'game/Simulation/cop356_german.crp').read_bytes(), b'asset')

    def test_cue_refuses_a_cooked_iso_declared_as_raw_bin(self):
        cue = self.cue()
        (self.root / 'disc.bin').write_bytes(image(raw=False))
        with self.assertRaisesRegex(DiscError, 'not raw MODE1'):
            Disc(cue)

    def test_cue_rejects_unsafe_file_reference(self):
        for name in ('../disc.bin', '/tmp/disc.bin', 'C:\\disc.bin'):
            with self.subTest(name=name), self.assertRaises(DiscError):
                Disc(self.cue(f'FILE "{name}" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n'))

    def test_cue_rejects_unsupported_layout(self):
        for text in ('FILE "disc.bin" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00',
                     'FILE "disc.bin" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:01',
                     'FILE "disc.bin" BINARY\nTRACK 01 MODE1/2352',
                     'FILE "disc.bin" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\nTRACK 02 AUDIO'):
            with self.subTest(text=text), self.assertRaises(DiscError):
                Disc(self.cue(text))

    def test_joliet_preserves_long_names_and_file_contents(self):
        with self.open_image(image()) as disc:
            self.assertEqual([str(e.path) for e in disc.entries()],
                             ['Simulation/cop356_german.crp'])
            disc.extract(self.root / 'game')
        self.assertEqual((self.root / 'game/Simulation/cop356_german.crp').read_bytes(), b'asset')

    def test_plain_iso_uses_the_same_joliet_paths(self):
        with self.open_image(image(raw=False)) as disc:
            disc.extract(self.root / 'game')
        self.assertEqual((self.root / 'game/Simulation/cop356_german.crp').read_bytes(), b'asset')

    def test_refuses_existing_destination_without_changing_it(self):
        destination = self.root / 'game'
        destination.mkdir()
        sentinel = destination / 'keep'
        sentinel.write_bytes(b'original')
        with self.open_image(image()) as disc:
            with self.assertRaises(FileExistsError):
                disc.extract(destination)
        self.assertEqual(list(destination.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b'original')

    def test_rejects_traversal_before_creating_output(self):
        with self.open_image(image('../escape')) as disc:
            with self.assertRaises(DiscError):
                disc.extract(self.root / 'game')
        self.assertFalse((self.root / 'game').exists())

    def test_rejects_truncated_image(self):
        with self.assertRaises(DiscError):
            self.open_image(image()[:-1])

    def test_corrupt_file_sector_cleans_new_output(self):
        data = bytearray(image())
        data[22 * 2352 + 15] = 2
        with self.open_image(data) as disc:
            with self.assertRaises(DiscError):
                disc.extract(self.root / 'game')
        self.assertFalse((self.root / 'game').exists())

    def test_out_of_range_extent_fails_before_output(self):
        data = bytearray(image())
        start = 21 * 2352 + 16
        struct.pack_into('<I', data, start + 2, 999)
        struct.pack_into('>I', data, start + 6, 999)
        with self.open_image(data) as disc:
            with self.assertRaises(DiscError):
                disc.extract(self.root / 'game')
        self.assertFalse((self.root / 'game').exists())


if __name__ == '__main__':
    unittest.main()
