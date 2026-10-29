#!/usr/bin/env python3
"""Send test input to this game's optional local control FIFO."""
import argparse
import os
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--fifo',default='out/control')
p.add_argument('action',choices=['press','down','up','text','mouse','click','move','tap','capture','audio','fullscreen','close','windowinfo'])
p.add_argument('values',nargs='*')
a=p.parse_args()
fd=os.open(a.fifo,os.O_WRONLY|os.O_NONBLOCK)
def send(s):
    os.write(fd,(s+'\n').encode('ascii'))
try:
    if a.action in ('capture','audio','fullscreen','close','windowinfo'):
        if a.values:p.error(f'{a.action} takes no values')
        send(a.action)
    elif a.action=='text':
        for ch in ' '.join(a.values):send(f'text {ord(ch)}');time.sleep(.05)
    elif a.action=='move':
        if len(a.values)!=2:p.error('move requires relative x y')
        send('move '+' '.join(str(int(v,0)) for v in a.values))
    elif a.action=='tap':
        if a.values:p.error('tap takes no values')
        send('button 0 1');time.sleep(.15);send('button 0 0')
    elif a.action=='click':
        if len(a.values)!=2:p.error('click requires x y')
        x,y=(int(v,0) for v in a.values)
        send(f'mouse {x} {y} 0 1 0');time.sleep(.15);send(f'mouse {x} {y} 0 0 0')
    elif a.action=='mouse':
        if len(a.values)!=5:p.error('mouse requires x y button down wheel')
        send('mouse '+' '.join(str(int(v,0)) for v in a.values))
    else:
        if len(a.values)!=2:p.error('key requires scan code and virtual key')
        scan,vk=(int(v,0) for v in a.values)
        send(f'key {scan} {vk} {0 if a.action=="up" else 1}')
        if a.action=='press' and (vk in (8,9,13,27,32) or 48<=vk<=57 or 65<=vk<=90):send(f'text {vk}')
        if a.action=='press':time.sleep(.15);send(f'key {scan} {vk} 0')
finally:
    os.close(fd)
