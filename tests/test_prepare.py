import hashlib
from types import SimpleNamespace
import unittest

from tools.prepare import section_extent, checked_bytes


class ImagePreparationTests(unittest.TestCase):
    def test_watcom_sections_have_extent_even_without_virtual_size(self):
        section = SimpleNamespace(Misc_VirtualSize=0, SizeOfRawData=0x1800)
        self.assertEqual(section_extent(section), 0x1800)

    def test_virtual_extent_wins_over_file_padding(self):
        section = SimpleNamespace(Misc_VirtualSize=0x1234, SizeOfRawData=0x1400)
        self.assertEqual(section_extent(section), 0x1234)

    def test_reject_changed_executable_before_parsing(self):
        with self.assertRaisesRegex(ValueError, 'checksum'):
            checked_bytes(b'changed', hashlib.sha256(b'original').hexdigest())


if __name__ == '__main__':
    unittest.main()
