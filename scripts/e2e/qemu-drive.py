import socket, subprocess, sys, time, os, shutil
img, mode, prefix = sys.argv[1:4]
Q='/opt/homebrew/share/qemu'; sock=f'/tmp/mq-{os.getpid()}.sock'; vars_=f'/tmp/mq-vars-{os.getpid()}.fd'
fw=[]
if mode=='uefi':
    shutil.copy(f'{Q}/edk2-i386-vars.fd', vars_)
    fw=['-drive',f'if=pflash,format=raw,readonly=on,file={Q}/edk2-x86_64-code.fd','-drive',f'if=pflash,format=raw,file={vars_}']
p=subprocess.Popen(['qemu-system-x86_64','-machine','q35','-m','1024','-snapshot',*fw,
  '-drive',f'file={img},format=raw,if=none,id=stick','-device','qemu-xhci','-device','usb-storage,drive=stick,bootindex=0',
  '-net','none','-serial',f'file:{prefix}-serial.log','-display','none','-vga','std','-monitor',f'unix:{sock},server,nowait'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
time.sleep(2); s=socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(2)
def cmd(c):
    s.sendall((c+'\n').encode()); time.sleep(0.5)
    try: s.recv(65536)
    except Exception: pass
# script: list of (sleep, action)
for step in sys.argv[4:]:
    kind,_,val=step.partition(':')
    if kind=='wait': time.sleep(float(val))
    elif kind=='key': cmd(f'sendkey {val}')
    elif kind=='shot': cmd(f'screendump {prefix}-{val}.png -f png'); print('   shot', val)
cmd('quit'); time.sleep(1); p.kill()
for f in (sock, vars_):
    try: os.remove(f)
    except OSError: pass
