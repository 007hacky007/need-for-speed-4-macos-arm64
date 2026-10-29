import json
import io
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools import addons


class AddonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def file(self, name, content=b'asset'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def test_windows_target_drops_prefix_and_activates_disabled_car(self):
        self.assertEqual(addons.game_target(r'C:\Old Game\Data\Cars\AMD7\--car.viv'),
                         'data/cars/amd7/car.viv')
        self.assertEqual(addons.game_target(r'D:\Old Game\Savedata\Cars\FMOD\car.FEC'),
                         'savedata/cars/fmod/car.fec')
        for path in (r'C:\Game\Data\Cars\..\escape.viv', r'C:\Game\Data\Cars\x\C:bad.viv',
                     r'C:\..\Game\Data\Cars\x\car.viv', r'C:\Game\Data\Cars\x\helper.exe',
                     r'C:\Game\Data\Menus\main.mnu', r'C:\Game\Data\Cars\x\car.viv.bak'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                addons.game_target(path)

    def test_car_maps_nested_case_insensitive_assets_and_keeps_fec(self):
        self.file('car/Nested/Car.ini', b'[Files]\nFileNr 1=C:\\Game\\Data\\Cars\\FMOD\\--car.viv\n'
                  b'FileNr 2=C:\\Game\\Data\\FeArt\\VidWall\\FMOD.qfs\n'
                  b'FileNr 3=C:\\Game\\Savedata\\Cars\\FMOD\\car.FEC\n'
                  b'FileNr 4=C:\\Game\\Data\\Cars\\FMOD\\Readme.txt\n'
                  b'FileNr 5=C:\\Game\\Data\\Cars\\FMOD\\car.viv.bak\n')
        viv = self.file('car/Nested/CAR.VIV')
        preview = self.file('car/Nested/fmod.QFS')
        fec = self.file('car/Nested/CAR.fec')
        self.file('car/Nested/Readme.txt', b'Author credits')
        self.assertEqual(addons.car_files(self.root / 'car'), [
            (viv, 'data/cars/fmod/car.viv'), (preview, 'data/feart/vidwall/fmod.qfs'),
            (fec, 'savedata/cars/fmod/car.fec'), (viv, 'savedata/cars/fmod/car.viv'),
            (preview, 'savedata/cars/fmod/fmod.qfs')])

    def test_car_art_and_other_active_assets_are_available_in_savedata(self):
        self.file('car/Car.ini', b'[Files]\nFileNr1=C:\\Game\\Data\\Cars\\NEWC\\--car.viv\n'
                  b'FileNr2=C:\\Game\\Data\\FeArt\\VidWall\\NEWC.qfs\n'
                  b'FileNr3=C:\\Game\\Data\\Showcase\\Art\\SHNEWC.qfs\n'
                  b'FileNr4=C:\\Game\\Data\\Cars\\NEWC\\IPSPCHe.viv\n'
                  b'FileNr5=C:\\Game\\Data\\Cars\\NEWC\\car.FEC\n'
                  b'FileNr6=C:\\Game\\Savedata\\Cars\\NEWC\\car.FEC\n')
        self.file('car/car.viv', b'model')
        self.file('car/NEWC.qfs', b'vidwall')
        self.file('car/SHNEWC.qfs', b'showcase')
        self.file('car/IPSPCHe.viv', b'optional model asset')
        self.file('car/car.FEC', b'explicit car configuration')
        mappings = addons.car_files(self.root / 'car')
        targets = [target for _, target in mappings]
        self.assertEqual(targets.count('savedata/cars/newc/car.fec'), 1)
        library = self.root / 'library'
        addons.install_profile(library, [], 'ep-car-newc', 'Test', self.root / 'car', mappings)
        overlay = library / 'ep-car-newc/Overlay'
        for target, content in (
                ('savedata/cars/newc/newc.qfs', b'vidwall'),
                ('savedata/cars/newc/shnewc.qfs', b'showcase'),
                ('savedata/cars/newc/ipspche.viv', b'optional model asset'),
                ('savedata/cars/newc/car.fec', b'explicit car configuration'),
                ('data/feart/vidwall/newc.qfs', b'vidwall'),
                ('data/showcase/art/shnewc.qfs', b'showcase'),
                ('data/cars/newc/ipspche.viv', b'optional model asset')):
            with self.subTest(target=target):
                self.assertEqual((overlay / target).read_bytes(), content)

    def test_new_car_profile_supplies_model_in_both_discovery_and_savedata_paths(self):
        self.file('car/Car.ini', b'[Files]\nFileNr1=C:\\Game\\Data\\Cars\\NEWC\\--car.viv\n')
        self.file('car/car.viv', b'new addon model')
        self.file('car/Readme.txt', b'Addon credits')
        library = self.root / 'library'
        profiles, report = [], []
        addons.prepare_profile(self.root / 'car', Path('New Car.zip'), 'Cars', library, profiles, report)
        overlay = library / 'ep-car-new-car/Overlay'
        self.assertEqual((overlay / 'data/cars/newc/car.viv').read_bytes(), b'new addon model')
        self.assertEqual((overlay / 'savedata/cars/newc/car.viv').read_bytes(), b'new addon model')
        self.assertIn('savedata/cars/newc/car.viv', report[0]['files'])
        self.assertEqual((library / 'ep-car-new-car/Notices/Readme.txt').read_bytes(), b'Addon credits')

    def test_ambiguous_and_missing_car_sources_are_unsupported(self):
        self.file('car/Car.ini', b'[Files]\nFileNr1=C:\\Game\\Data\\Cars\\x\\--car.viv\n')
        self.file('car/a/car.viv')
        self.file('car/b/CAR.VIV')
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            addons.car_files(self.root / 'car')
        (self.root / 'car/a/car.viv').unlink()
        (self.root / 'car/b/CAR.VIV').unlink()
        with self.assertRaisesRegex(ValueError, 'missing'):
            addons.car_files(self.root / 'car')

    def test_track_routes_slot_and_renames_promotional_art(self):
        self.file('track/Folder/Mixer.ini', b'[TrackData]\nName=* Angel Lake 3\nBased On=3\n')
        geometry = self.file('track/Folder/Tr.frd')
        config = self.file('track/Folder/Tr.ini')
        textures = self.file('track/Folder/TR0.qFS')
        night = self.file('track/Folder/TrN.frd')
        preview = self.file('track/Folder/T05.qfs')
        slide = self.file('track/Folder/T5_00.qfs')
        self.file('track/Folder/readme.txt', b'Credits')
        self.file('track/Folder/install.bat', b'never execute')
        name, mappings = addons.track_files(self.root / 'track')
        self.assertEqual(name, 'Angel Lake 3 (replaces Park, Expansion)')
        self.assertEqual(dict((target, source) for source, target in mappings), {
            'data/tracks/park/tr.frd': geometry, 'data/tracks/park/tr0.qfs': textures,
            'data/tracks/park/tr.ini': config,
            'data/tracks/park/trn.frd': night, 'data/feart/vidwall/t03.qfs': preview,
            'data/feart/slides/t3_00.qfs': slide})

    def test_track_rejects_unknown_slot_and_incomplete_geometry(self):
        config = self.file('track/Mixer.ini', b'[TrackData]\nName=Test\nBased On=19\n')
        with self.assertRaisesRegex(ValueError, 'slot'):
            addons.track_files(self.root / 'track')
        config.write_bytes(b'[TrackData]\nName=Test\nBased On=16\n')
        self.file('track/Tr.frd')
        with self.assertRaisesRegex(ValueError, 'tr0.qfs'):
            addons.track_files(self.root / 'track')

    def test_profile_normalizes_casing_and_preserves_notices_outside_overlay(self):
        source = self.file('source/Nested/Readme.txt', b'Creator license')
        payload = self.file('source/car.viv')
        profiles = []
        addons.install_profile(self.root / 'library', profiles, 'ep-car-test', 'Test (Expansion)',
                               self.root / 'source', [(payload, 'Data/Cars/TEST/CAR.VIV')])
        self.assertEqual(profiles, [{'id': 'ep-car-test', 'name': 'Test (Expansion)'}])
        self.assertEqual((self.root / 'library/ep-car-test/Overlay/data/cars/test/car.viv').read_bytes(), b'asset')
        self.assertEqual((self.root / 'library/ep-car-test/Notices/Nested/Readme.txt').read_bytes(), source.read_bytes())
        self.assertFalse(list((self.root / 'library/ep-car-test/Overlay').rglob('*.txt')))

    def test_profile_rejects_id_and_overlay_case_collisions_before_writing(self):
        payload = self.file('source/car.viv')
        library = self.root / 'library'
        profiles = [{'id': 'ep-car-test', 'name': 'Existing'}]
        for profile_id, files in (
                ('ep-car-test', [(payload, 'data/cars/x/car.viv')]),
                ('original', [(payload, 'data/cars/x/car.viv')]),
                ('../escape', [(payload, 'data/cars/x/car.viv')]),
                ('ep-car-other', [(payload, 'Data/Cars/x/car.viv'), (payload, 'data/cars/X/CAR.VIV')]),
                ('ep-car-other', [(payload, 'data/cars/x'), (payload, 'data/cars/x/car.viv')])):
            with self.subTest(profile_id=profile_id, files=files), self.assertRaises(ValueError):
                addons.install_profile(library, profiles, profile_id, 'Test', self.root / 'source', files)
        self.assertFalse(library.exists())

    def test_archive_failure_is_reported_without_publishing_partial_profile(self):
        self.file('bad/Car.ini', b'[Files]\nFileNr1=C:\\Game\\Data\\Cars\\x\\--car.viv\n')
        library = self.root / 'library'
        report, profiles = [], []
        addons.prepare_profile(self.root / 'bad', Path('Broken car.zip'), 'Cars', library, profiles, report)
        self.assertEqual(profiles, [])
        self.assertEqual(report[0]['status'], 'unsupported')
        self.assertEqual(report[0]['archive'], 'Broken car.zip')
        self.assertIn('missing', report[0]['reason'])
        self.assertFalse(library.exists())

    @unittest.skipUnless(shutil.which('7zz'), 'requires portable 7-Zip')
    def test_complete_library_extracts_only_assets_and_records_unsupported_archives(self):
        def archive_bytes(files):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, 'w') as archive:
                for name, content in files.items():
                    archive.writestr(name, content)
            return buffer.getvalue()

        car = archive_bytes({'nested/Car.ini': '[Files]\nFileNr1=C:\\Game\\Data\\Cars\\test\\--car.viv\n',
                             'nested/car.viv': b'car', 'nested/readme.txt': b'Car author'})
        track = archive_bytes({'Mixer.ini': '[TrackData]\nName=Test Track\nBased On=16\n',
                               'Tr.frd': b'geometry', 'tr0.qfs': b'textures', 'Tr.ini': b'config'})
        payload = {'$TEMP/Cars/Test Car.zip': car, '$TEMP/Cars/Unsupported.zip': archive_bytes({'readme.txt': b'No mapping'}),
                   '$TEMP/Tracks/Test Track.zip': track, 'NFS_HS_SP-EP.txt': b'Pack credits',
                   'Windows/helper.exe': b'never include'}
        for name in ('Caprice', 'Hatchbk', 'sedan', 'suv'):
            payload[f'Data/Cars/traffic/Pursuit_HOT/{name}/car.viv'] = name.encode()
        outer = self.file('fixture.rar', archive_bytes({
            'NFS_HS_EP_Setup_V4.0_(1.78).exe': archive_bytes(payload)}))
        with patch.object(addons, 'fetch', return_value=outer):
            library = addons.prepare_addons(self.root, Path(shutil.which('7zz')))
        catalog = json.loads((library / 'catalog.json').read_text())
        self.assertEqual({p['id'] for p in catalog['profiles']},
                         {'ep-car-test-car', 'ep-track-test-track', 'ep-traffic-hot-pursuit'})
        self.assertNotIn('build_id', catalog)
        self.assertEqual((library / 'ep-car-test-car/Overlay/data/cars/test/car.viv').read_bytes(), b'car')
        self.assertEqual((library / 'ep-car-test-car/Overlay/savedata/cars/test/car.viv').read_bytes(), b'car')
        self.assertEqual((library / 'ep-car-test-car/Notices/nested/readme.txt').read_bytes(), b'Car author')
        report = json.loads((library / 'preparation.json').read_text())
        unsupported = [entry for entry in report['archives'] if entry['status'] == 'unsupported']
        self.assertEqual(len(unsupported), 1)
        self.assertEqual(unsupported[0]['archive'], 'Unsupported.zip')
        self.assertIn('car.ini', unsupported[0]['reason'])
        self.assertFalse(any(p.suffix.lower() == '.exe' for p in library.rglob('*')))
        self.assertFalse(list(self.root.glob('addons-work-*')))


if __name__ == '__main__':
    unittest.main()
