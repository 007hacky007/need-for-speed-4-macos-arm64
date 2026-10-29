from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InputTests(unittest.TestCase):
    def test_virtual_button_swap_changes_messages_and_preserves_physical_input(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/input.c"
int main(void){
 if(input_swap_buttons(1))return 1;
 input_mouse(0,0,0,1,0);
 if(message_count!=1||messages[0].message!=0x204||messages[0].wp!=2)return 2;
 unsigned char state[16];input_mouse_state(state,sizeof state);
 if(state[12]!=128||state[13])return 3;
 if(input_swap_buttons(0)!=1)return 4;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
