"""Prepare isolated community asset profiles without running pack installers."""
import configparser
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile

try:
    from .downloads import extract_7z, fetch, safe_path
except ImportError:
    from downloads import extract_7z, fetch, safe_path


EXPANSION_URL = 'https://www.iplounge.net/dloads/hsfull.rar'
EXPANSION_SHA256 = 'efe0c834fb7a2a26ba5870b5e723516184ed60e027b95bc9edb5232ff62f57fc'
TRACK_SLOTS = ('Hills', 'Germany', 'Coastal', 'Park', 'France', 'Uk', 'Snowy', 'Gt1',
               'Gt2', 'Gt3', 'Hometown', 'Redrock', 'Atlantic', 'RockyPas', 'Country',
               'LostCany', 'Aquatica', 'Summit', 'Empire')
NOTICE_SUFFIXES = {'.txt', '.html', '.htm', '.md', '.rtf', '.pdf', '.doc', '.docx',
                   '.gif', '.jpg', '.jpeg', '.png'}
CAR_SUFFIXES = {'.viv', '.qfs', '.fec', '.tga'}
TRACK_SUFFIXES = {'.frd', '.qfs', '.ini', '.can', '.sim', '.bin', '.cam'}


def game_target(windows_path):
    """Accept only known game asset destinations from old Windows Car.ini files."""
    parts = windows_path.strip().replace('\\', '/').split('/')
    if (any(p in ('.', '..') or any(ord(c) < 32 for c in p) for p in parts)
            or any(':' in p and not (i == 0 and re.fullmatch('[A-Za-z]:', p))
                   for i, p in enumerate(parts))):
        raise ValueError('unsafe Windows asset path')
    starts = [i for i, part in enumerate(parts) if part.lower() in ('data', 'savedata')]
    if len(starts) != 1:
        raise ValueError('missing or ambiguous game data component')
    target = [part.lower() for part in parts[starts[0]:]]
    if not all(target):
        raise ValueError('empty asset path component')
    if target[-1].startswith('--'):
        target[-1] = target[-1][2:]
    path = PurePosixPath(*target)
    if (len(target) == 4 and target[:2] == ['data', 'cars']
            and path.suffix in {'.viv', '.qfs', '.tga', '.fec'}):
        return path.as_posix()
    if (len(target) == 4 and target[:2] == ['savedata', 'cars']
            and target[-1] == 'car.fec'):
        return path.as_posix()
    if (len(target) == 4 and (target[:3] in (['data', 'feart', 'vidwall'],
                                            ['data', 'feart', 'slides'],
                                            ['data', 'showcase', 'art'])) and path.suffix == '.qfs'):
        return path.as_posix()
    raise ValueError('unsupported game asset destination')


def read_config(source, name):
    candidates = [p for p in source.rglob('*') if p.is_file() and p.name.lower() == name]
    if len(candidates) != 1:
        raise ValueError(f'missing or ambiguous {name}')
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(candidates[0].read_bytes().decode('cp1252'))
    return config


def car_files(source):
    config = read_config(source, 'car.ini')
    if not config.has_section('Files'):
        raise ValueError('missing Car.ini Files section')
    available = {}
    for path in source.rglob('*'):
        if path.is_file():
            available.setdefault(path.name.lower().removeprefix('--'), []).append(path)
    mappings = []
    for key, destination in config['Files'].items():
        if not re.fullmatch(r'filenr\s*\d+', key):
            raise ValueError(f'unsupported Car.ini file key: {key}')
        if PurePosixPath(destination.replace('\\', '/')).suffix.lower() not in CAR_SUFFIXES:
            continue
        target = game_target(destination)
        basename = PurePosixPath(target).name
        matches = available.get(basename, [])
        if len(matches) != 1:
            raise ValueError(f'{"missing" if not matches else "ambiguous"} source asset: {basename}')
        mappings.append((matches[0], target))
    cars = {PurePosixPath(target).parent for _, target in mappings
            if target.startswith('data/cars/') and PurePosixPath(target).name == 'car.viv'}
    if len(cars) != 1:
        raise ValueError('profile must contain exactly one car.viv destination')
    # The original addon loader discovers metadata in Data but loads models/art from Savedata.
    model_id = next(iter(cars)).name
    explicit = {target for _, target in mappings}
    mirrors = {}
    for asset, target in mappings:
        if target.startswith('data/cars/'):
            mirror = target.replace('data/', 'savedata/', 1)
        elif target.startswith(('data/feart/vidwall/', 'data/showcase/art/')):
            mirror = f'savedata/cars/{model_id}/{PurePosixPath(target).name}'
        else:
            continue
        if mirror in explicit:
            continue
        if mirror in mirrors and mirrors[mirror] != asset:
            raise ValueError(f'conflicting addon compatibility asset: {mirror}')
        mirrors[mirror] = asset
    return mappings + [(asset, target) for target, asset in mirrors.items()]


def track_files(source):
    config = read_config(source, 'mixer.ini')
    try:
        slot = int(config['TrackData']['Based On'])
        if not 0 <= slot < len(TRACK_SLOTS):
            raise ValueError()
    except (KeyError, ValueError) as error:
        raise ValueError('missing or unsupported track slot') from error
    name = config['TrackData'].get('Name', source.name).strip().lstrip('*').strip()
    mappings = []
    for path in sorted(source.rglob('*')):
        if not path.is_file() or path.suffix.lower() not in TRACK_SUFFIXES or path.name.lower() == 'mixer.ini':
            continue
        basename = path.name.lower()
        if re.fullmatch(r't\d+\.qfs', basename):
            target = f'data/feart/vidwall/t{slot:02d}.qfs'
        elif re.fullmatch(r't\d+_\d+\.qfs', basename):
            slide = basename.split('_', 1)[1]
            target = f'data/feart/slides/t{slot}_{slide}'
        else:
            target = f'data/tracks/{TRACK_SLOTS[slot].lower()}/{basename}'
        mappings.append((path, target))
    names = {PurePosixPath(target).name for _, target in mappings}
    for required in ('tr.frd', 'tr0.qfs', 'tr.ini'):
        if required not in names:
            raise ValueError(f'missing track asset: {required}')
    # The pinned pack supplies night assets where the original slot has them.
    # Do not synthesize geometry/texture variants or copy assets from other tracks.
    return f'{name} (replaces {TRACK_SLOTS[slot]}, Expansion)', mappings


def install_profile(library, profiles, profile_id, name, source, mappings, notice=None):
    """Validate a complete overlay before publishing the profile or its catalog row."""
    if (not re.fullmatch(r'[a-z0-9_-]{1,64}', profile_id) or profile_id == 'original'
            or any(p['id'] == profile_id for p in profiles) or (library / profile_id).exists()):
        raise ValueError(f'invalid or duplicate profile id: {profile_id}')
    normalized = []
    paths = set()
    for asset, target in mappings:
        path = safe_path(target.lower())
        key = path.as_posix()
        if (key in paths or any(parent.as_posix() in paths for parent in path.parents)
                or any(previous.startswith(key + '/') for previous in paths)):
            raise ValueError(f'overlay case or path collision: {key}')
        if asset.is_symlink() or not asset.is_file():
            raise ValueError('unsupported source asset')
        paths.add(key)
        normalized.append((asset, path))
    if not normalized:
        raise ValueError('empty overlay')
    profile = library / profile_id
    try:
        for asset, target in normalized:
            destination = profile / 'Overlay' / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(asset, destination)
        for path in sorted(source.rglob('*')):
            if path.is_file() and (path.suffix.lower() in NOTICE_SUFFIXES
                                   or path.name.lower() in ('license', 'copying', 'car.ini', 'mixer.ini')):
                destination = profile / 'Notices' / path.relative_to(source)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
        if notice is not None:
            shutil.copyfile(notice, profile / 'Pack-Notice.txt')
    except BaseException:
        shutil.rmtree(profile, ignore_errors=True)
        raise
    profiles.append({'id': profile_id, 'name': name})


def prepare_profile(source, archive, kind, library, profiles, report, notice=None):
    profile_id = 'ep-' + kind[:-1].lower() + '-' + re.sub(r'[^a-z0-9]+', '-', archive.stem.lower()).strip('-')
    try:
        if kind == 'Cars':
            mappings = car_files(source)
            name = f'{archive.stem} (Expansion)'
        else:
            name, mappings = track_files(source)
        install_profile(library, profiles, profile_id, name, source, mappings, notice)
    except (ValueError, configparser.Error) as error:
        report.append({'archive': archive.name, 'status': 'unsupported', 'reason': str(error)})
        return
    report.append({'archive': archive.name, 'status': 'prepared', 'id': profile_id,
                   'files': [target for _, target in mappings]})


def prepare_addons(cache_dir: Path, extractor: Path) -> Path:
    """Return a private library with one selected car, track or traffic overlay per profile."""
    cache_dir = Path(cache_dir)
    archive = fetch(cache_dir, 'hsfull.rar', EXPANSION_URL, EXPANSION_SHA256)
    library = Path(tempfile.mkdtemp(prefix='addons-', dir=cache_dir))
    profiles, report = [], []
    try:
        with tempfile.TemporaryDirectory(prefix='addons-work-', dir=cache_dir) as temporary:
            work = Path(temporary)
            extract_7z(archive, work / 'outer', extractor)
            installers = list((work / 'outer').rglob('NFS_HS_EP_Setup_V4.0_(1.78).exe'))
            if len(installers) != 1:
                raise ValueError('missing or ambiguous pinned Expansion installer')
            payload = work / 'payload'
            extract_7z(installers[0], payload, extractor, include=(
                '$TEMP/Cars', '$TEMP/Tracks', 'Data/Cars/traffic/Pursuit_HOT', 'NFS_HS_SP-EP.txt'))
            notice = payload / 'NFS_HS_SP-EP.txt'
            traffic = payload / 'Data/Cars/traffic/Pursuit_HOT'
            mappings = [(path, f'data/cars/traffic/pursuit/{path.parent.name.lower()}/car.viv')
                        for path in sorted(traffic.rglob('*')) if path.is_file() and path.name.lower() == 'car.viv']
            if {PurePosixPath(target).parent.name for _, target in mappings} != {'caprice', 'hatchbk', 'sedan', 'suv'}:
                raise ValueError('incomplete pursuit traffic assets')
            install_profile(library, profiles, 'ep-traffic-hot-pursuit', 'Hot Pursuit traffic addon (Stock/Expansion)',
                            traffic, mappings, notice)
            for kind in ('Cars', 'Tracks'):
                for index, nested in enumerate(sorted((payload / '$TEMP' / kind).iterdir())):
                    if nested.suffix.lower() not in ('.rar', '.zip'):
                        report.append({'archive': nested.name, 'status': 'unsupported', 'reason': 'unknown archive type'})
                        continue
                    source = work / kind / str(index)
                    try:
                        extract_7z(nested, source, extractor)
                    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                        report.append({'archive': nested.name, 'status': 'unsupported', 'reason': str(error)})
                        continue
                    prepare_profile(source, nested, kind, library, profiles, report, notice)
            (library / 'catalog.json').write_text(json.dumps({'profiles': profiles}, indent=2) + '\n')
            (library / 'preparation.json').write_text(json.dumps({
                'source': EXPANSION_URL, 'sha256': EXPANSION_SHA256, 'archives': report}, indent=2) + '\n')
    except BaseException:
        shutil.rmtree(library)
        raise
    return library
