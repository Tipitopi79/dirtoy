# Fenstertest: bedient das echte DirToy-Fenster mit Testordnern (nur Windows, Testdateien landen im Papierkorb).
# Start: python tests/test-fenster.py [--bilder <ordner>]   (Bilder brauchen Pillow)
import json, os, shutil, subprocess, sys, tempfile, time
from fenster import *
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
        def start(): mklick(m, 'btnRun'); return wait(p.pid, T)
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
