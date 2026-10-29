"""Compile this project's shaders, never game data, to a private build header."""
import json
import os
import shutil
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def build_shaders():
    target = ROOT / 'gen/all'
    target.mkdir(parents=True, exist_ok=True)
    metal = 'static const char metal_shader[] = ' + json.dumps((ROOT / 'runtime/scene.metal').read_text()) + ';\n'
    header = target / 'shader.h'
    if not header.exists() or header.read_text() != metal:
        header.write_text(metal)
    compiler = os.environ.get('NFSIV_GLSLANG') or shutil.which('glslang') or str(ROOT / 'local/glslang-build/StandAlone/glslang')
    compiler_path = Path(compiler)
    if not compiler_path.is_file():
        raise RuntimeError('Shader compiler is missing. Run ./build.sh to fetch and build the dependencies.')
    sources = [ROOT / 'runtime' / ('scene.' + stage) for stage in ('vert', 'frag')]
    header = target / 'vulkan_shader.h'
    if header.exists() and header.stat().st_mtime >= max(p.stat().st_mtime for p in [compiler_path, *sources]):
        return
    code = ''
    for source in sources:
        output = target / (source.name + '.spv')
        subprocess.run([compiler, '-V', str(source), '-o', str(output)], check=True)
        data = output.read_bytes()
        words = struct.unpack('<' + 'I' * (len(data) // 4), data)
        code += 'static const uint32_t vulkan_' + source.suffix[1:] + '[] = {' + ','.join(hex(i) for i in words) + '};\n'
    header.write_text(code)


if __name__ == '__main__':
    build_shaders()
