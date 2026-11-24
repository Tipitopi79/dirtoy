# Fenstertest: bedient das echte DirToy-Fenster mit Testordnern (nur Windows, Testdateien landen im Papierkorb).
# Start: python tests/test-fenster.py [--bilder <ordner>]   (Bilder brauchen Pillow)
import ctypes, json, os, re, shutil, subprocess, sys, tempfile, time
from ctypes import wintypes as W
u, g = ctypes.windll.user32, ctypes.windll.gdi32
CB = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
for f in (u.GetWindowDC, g.CreateCompatibleDC, g.CreateCompatibleBitmap, g.SelectObject): f.restype = ctypes.c_void_p
u.GetWindowDC.argtypes = [W.HWND]; g.CreateCompatibleDC.argtypes = [ctypes.c_void_p]
g.CreateCompatibleBitmap.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]; g.SelectObject.argtypes = [ctypes.c_void_p] * 2
g.GetDIBits.argtypes = [ctypes.c_void_p, ctypes.c_void_p, W.UINT, W.UINT, ctypes.c_void_p, ctypes.c_void_p, W.UINT]
u.PrintWindow.argtypes = [W.HWND, ctypes.c_void_p, W.UINT]
out = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == '--bilder' else None
PS1 = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'DirToy.ps1')
VER = re.search(r"script:version = '([\d.]+)'", open(PS1, encoding='utf-8-sig').read()).group(1)
def text(h):
    b = ctypes.create_unicode_buffer(300); u.GetWindowTextW(h, b, 300); return b.value
def tops(pid):
    r = []
    def cb(h, _):
        p = W.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid and u.IsWindowVisible(h): r.append(h)
        return True
    u.EnumWindows(CB(cb), 0); return r
def wait(pid, title, sec=20, gone=False):
    end = time.time() + sec
    while time.time() < end:
        m = [h for h in tops(pid) if text(h) == title]
        if gone and not m: return True
        if m and not gone: time.sleep(0.6); return m[0]
        time.sleep(0.1)
    raise SystemExit(f'Fenster: {title} gone={gone}, da: {[text(h) for h in tops(pid)]}')
def child(h, t):
    r = []
    u.EnumChildWindows(h, CB(lambda c, _: (r.append(c) if text(c) == t else None) or True), 0)
    if not r: raise SystemExit('kein Knopf ' + t)
    return r[0]
def click(h, t): u.PostMessageW(child(h, t), 0x00F5, 0, 0)
def key(h, k): u.PostMessageW(h, 0x0100, k, 0); u.PostMessageW(h, 0x0101, k, 0)
def shot(h, name):
    if not out: return
    from PIL import Image
    r = W.RECT(); u.GetWindowRect(h, ctypes.byref(r)); w, hh = r.right - r.left, r.bottom - r.top
    dc = u.GetWindowDC(h); m = g.CreateCompatibleDC(dc); b = g.CreateCompatibleBitmap(dc, w, hh); g.SelectObject(m, b)
    u.PrintWindow(h, m, 2)
    import struct
    bi = ctypes.create_string_buffer(struct.pack('<IiiHHIIiiII', 40, w, -hh, 1, 32, 0, 0, 0, 0, 0, 0)); d = ctypes.create_string_buffer(w * hh * 4)
    g.GetDIBits(m, b, 0, hh, d, bi, 0)
    Image.frombuffer('RGB', (w, hh), d, 'raw', 'BGRX', 0, 1).save(os.path.join(out, name))
def run(theme, asked=True):
    d = tempfile.mkdtemp(prefix='dirtoy-gui-'); A, B, D = (os.path.join(d, x) for x in ('A', 'B', 'daten'))
    for x in (A, B, D, os.path.join(d, 'desk')): os.mkdir(x)
    fs = [os.path.join(B, f'{i}.txt') for i in range(3)]
    for f in fs: open(f, 'w').write('x')
    json.dump([dict(Id='a' * 32, Name='Test', A=A, B=B, Mode=1, Exclude='', ExcludeDirs=[], Schedule=None, SchedName='', AutoLnk='')], open(os.path.join(D, 'aufgaben.json'), 'w'))
    json.dump(dict(Theme=theme, ShortcutAsked=asked, UpdateCheck=False, ShowResult=False), open(os.path.join(D, 'einstellungen.json'), 'w'))
    e = dict(os.environ, DIRTOY_DATA=D, DIRTOY_DESKTOP=os.path.join(d, 'desk'))
    p = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', PS1], env=e, creationflags=0x08000000)
    return d, fs, p
T = 'Auffällig viele Löschungen'; ok = True
def check(n, c):
    global ok; ok &= bool(c); print('ok ' if c else 'FEHLER', n)
for theme in ('dunkel', 'hell'):
    d, fs, p = run(theme)
    try:
        m = wait(p.pid, 'DirToy ' + VER)
        there = lambda: all(os.path.exists(f) for f in fs)
        def start(): click(m, 'Synchronisieren'); return wait(p.pid, T)
        w = start(); shot(w, f'warn-{theme}.png'); key(w, 13); wait(p.pid, T, gone=True); time.sleep(0.7); check(theme + ': Enter = Nein, Dateien da', there())
        w = start(); key(w, 27); wait(p.pid, T, gone=True); time.sleep(0.7); check(theme + ': Esc = Nein, Dateien da', there())
        w = start(); u.PostMessageW(w, 0x0010, 0, 0); wait(p.pid, T, gone=True); time.sleep(0.7); check(theme + ': X = Nein, Dateien da', there())
        w = start(); click(w, 'Nein'); wait(p.pid, T, gone=True); time.sleep(0.7); check(theme + ': Nein, Dateien da', there())
        w = start(); click(w, 'Ja'); wait(p.pid, T, gone=True); time.sleep(3); check(theme + ': Ja loescht', not any(os.path.exists(f) for f in fs))
        u.PostMessageW(m, 0x0010, 0, 0); p.wait(10)
        check(theme + ': kein Fehlerprotokoll', not os.path.exists(os.path.join(d, 'daten', 'fehler.log')))
    finally:
        p.poll() is None and p.kill(); shutil.rmtree(d, ignore_errors=True)
d, fs, p = run('dunkel', False)
try:
    w = wait(p.pid, 'DirToy'); shot(w, 'willkommen.png'); click(w, 'Nein'); wait(p.pid, 'DirToy', gone=True); time.sleep(0.5)
    check('Willkommen Nein: keine Verknuepfung', not os.listdir(os.path.join(d, 'desk')))
finally:
    p.poll() is None and p.kill(); shutil.rmtree(d, ignore_errors=True)
print('ALLES OK' if ok else 'FEHLER')
sys.exit(0 if ok else 1)
