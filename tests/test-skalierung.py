# Fenstertest fuer kleine Bildschirme / hohe Skalierung: kein Fenster darf groesser sein als der Bildschirm, Knoepfe bleiben erreichbar.
# Die Bildschirmgroesse wird in einer Kopie vorgetaeuscht. Start: python tests/test-skalierung.py [--bilder <ordner>]
import json, os, shutil, subprocess, sys, tempfile, time
from fenster import *
ok = True
def check(n, c):
    global ok
    ok &= bool(c); print('ok ' if c else 'FEHLER', n, flush=True)
quelle = open(PS1, encoding='utf-8-sig', newline='').read()
alt = 'function Get-WorkSize {'; assert quelle.count(alt) == 1
neu = 'function Start-UpdateCheck([bool]$manual) {'; assert quelle.count(neu) == 1
def rect(h): r = W.RECT(); u.GetWindowRect(h, ctypes.byref(r)); return r.left, r.top, r.right, r.bottom
def groesse(h): r = rect(h); return r[2] - r[0], r[3] - r[1]
def drin(h, id, **k):   # sichtbar und ganz innerhalb des Fensters
    r = uia('get', h, id, **k); f, e = rect(h), r.get('rect')
    return bool(r['found'] and r['visible'] and e and e[0] >= f[0] and e[1] >= f[1] and e[2] <= f[2] and e[3] <= f[3] - 4)
for name, w0, h0 in (('150 Prozent', 1280, 672), ('175 Prozent', 1097, 577), ('200 Prozent', 960, 500)):
    print('== Full HD mit', name)
    d = tempfile.mkdtemp(prefix='dirtoy-skal-'); D, A, B = (os.path.join(d, x) for x in ('daten', 'A', 'B'))
    for x in (D, A, B): os.mkdir(x)
    ps1 = os.path.join(d, 'DirToy.ps1')
    open(ps1, 'w', encoding='utf-8-sig', newline='').write(quelle.replace(alt, alt + f'\r\n    return [System.Windows.Size]::new({w0}, {h0})\r\n').replace(neu, neu + "\r\n    if ($manual) { [void](Show-UpdateDialog ([pscustomobject]@{ Version = [version]'9.9.9'; Notes = 'x'; Url = 'x'; Tag = 'v9.9.9' }) 'new') }; return"))
    json.dump(dict(Theme='dunkel', ShortcutAsked=True, UpdateCheck=False, ShowResult=True), open(os.path.join(D, 'einstellungen.json'), 'w'))
    json.dump([dict(Id='c' * 32, Name='Test', A=A, B=B, Mode=0, Exclude='', ExcludeDirs=[], Schedule=None, SchedName='', AutoLnk='')], open(os.path.join(D, 'aufgaben.json'), 'w'))
    open(os.path.join(A, 'x.txt'), 'w').write('x')
    p = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ps1], env=dict(os.environ, DIRTOY_DATA=D), creationflags=0x08000000)
    try:
        m = wait(p.pid, 'DirToy ' + VER); time.sleep(.4); n = name[:3]
        aw = ctypes.c_int(); h = ctypes.windll.kernel32.OpenProcess(0x1000, False, p.pid); ctypes.windll.shcore.GetProcessDpiAwareness(h, ctypes.byref(aw))
        check('Programm ist skalierungsfaehig (nicht unscharf)', aw.value >= 1)
        f = u.GetDpiForWindow(m) / 96
        def passt(h, was): s = groesse(h); check(f'{was} {s} passt', s[0] <= w0 * f + 1 and s[1] <= h0 * f + 1); shot(h, f'skal-{n}-{was}.png')
        def da(h, *ids): check('erreichbar: ' + ', '.join(ids), all(drin(h, i) for i in ids))
        passt(m, 'Hauptfenster'); da(m, 'btnRun', 'btnAll', 'btnPrev', 'btnHelp', 'btnNew', 'lblStatus', 'lv', 'm2')
        mklick(m, 'btnGear'); time.sleep(.4); da(m, 'tbEx', 'btnDel', 'btnDirs', 'btnRun', 'lblStatus'); shot(m, f'skal-{n}-Zahnrad.png')
        for id, t, ids in (('btnSched', 'Zeitplan', ('head', 't3')), ('btnDirs', 'Ordner auswählen', ('count',)), ('btnHelp', 'DirToy - Hilfe', ('showRes',)), ('lblVer', 'DirToy - Update', ('head',)), ('btnRun', 'DirToy - Ergebnis', ('head',))):
            mklick(m, id); w = wait(p.pid, t)
            if t == 'Zeitplan': mklick(w, 't1'); time.sleep(.4)
            passt(w, t.split(' ')[-1]); da(w, *ids)
            if t in ('Zeitplan', 'Ordner auswählen'):
                uia('focus', w, 'Abbrechen', byname=True); time.sleep(.3)
                check('Abbrechen sichtbar (ggf. gescrollt)', drin(w, 'Abbrechen', byname=True)); click(w, 'Abbrechen')
            elif t == 'DirToy - Update':
                uia('focus', w, 'later'); time.sleep(.3); check('Spaeter sichtbar (ggf. gescrollt)', drin(w, 'later')); mklick(w, 'later')
            else: check('Schliessen sichtbar', drin(w, 'Schließen', byname=True)); click(w, 'Schließen')
            wait(p.pid, t, gone=True); time.sleep(.3)
        u.PostMessageW(m, 0x0010, 0, 0); p.wait(10); check('kein Fehlerprotokoll', not os.path.exists(os.path.join(D, 'fehler.log')))
    finally:
        if p.poll() is None: p.kill(); p.wait()
        if os.path.exists(os.path.join(D, 'fehler.log')): print(open(os.path.join(D, 'fehler.log'), encoding='utf-8-sig').read()[:800])
        shutil.rmtree(d, ignore_errors=True)
print('ALLES OK' if ok else 'FEHLER')
sys.exit(0 if ok else 1)
