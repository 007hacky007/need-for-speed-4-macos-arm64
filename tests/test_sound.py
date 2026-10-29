from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SoundTests(unittest.TestCase):
    def test_coreaudio_does_not_expose_a_windows_global_hardware_mixer(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/sound.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
CPU *g_cur_cpu;
int main(void){
 CPU cpu={0};uint32_t result=99;
 if(!sound_platform_call(&cpu,"WINMM.dll","mixerGetNumDevs",&result)||result)return 1;
 if(!sound_platform_call(&cpu,"WINMM.dll","mixerGetLineInfoA",&result)||result!=2)return 2;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
