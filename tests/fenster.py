# Gemeinsame Hilfen der Fenstertests (nur Windows). Anderes Programm testen: Umgebungsvariable DIRTOY_TEST_PS1
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
PS1 = os.environ.get('DIRTOY_TEST_PS1') or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'DirToy.ps1')
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
