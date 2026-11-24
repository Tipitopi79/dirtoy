# Fenstertest fuer den Lauf: Abbrechen, Schliessen, Rueckfragen, Vorschau, Fehler, Aenderungen waehrend des Laufs.
# Ordner B woanders (z. B. auf einem NAS): Umgebungsvariable DIRTOY_TEST_B=<ordner>; dort wird nur ein eigener Unterordner benutzt.
# Start: python tests/test-ablauf.py        braucht voruebergehend rund 3 GB im Temp-Ordner
import ctypes, json, os, shutil, subprocess, sys, tempfile, time
from fenster import *
ok = True
def check(n, c):
    global ok
    ok &= bool(c); print('ok ' if c else 'FEHLER', n, flush=True)
def dateien(d): return sorted(os.path.relpath(os.path.join(o, f), d) for o, _, fs in os.walk(d) for f in fs)
def texte(m):
    r = []; u.EnumChildWindows(m, CB(lambda c, _: (r.append(text(c)) or True)), 0); return r
GEDULD = 6 if os.environ.get('DIRTOY_TEST_B') else 1   # Netzlaufwerke sind langsamer
def bis(f, sec, was):
    sec *= GEDULD
    end = time.time() + sec
    while time.time() < end:
        if f(): return time.time() - (end - sec)
        time.sleep(0.02)
    check('ZEIT ABGELAUFEN: ' + was, False); raise SystemExit(1)
def antwort(m):   # laengste Zeit, die das Fenster nicht reagiert (bis 5 s)
    t = time.time(); r = ctypes.c_size_t(); u.SendMessageTimeoutW(m, 0, 0, 0, 0, 5000, ctypes.byref(r)); return time.time() - t
def knopf_sichtbar(m, id): r = uia('get', m, id); return r['found'] and r['visible']
def kinder(m):
    r = []; u.EnumChildWindows(m, CB(lambda c, _: (r.append(c) or True)), 0); return r
class Lauf:
    def __init__(self, n=1):
        self.d = tempfile.mkdtemp(prefix='dirtoy-abl-'); self.D = os.path.join(self.d, 'daten'); os.mkdir(self.D)
        self.n = tempfile.mkdtemp(prefix='dirtoy-abl-', dir=os.environ['DIRTOY_TEST_B']) if os.environ.get('DIRTOY_TEST_B') else self.d
        self.paare = []
        for i in range(n):
            A, B = os.path.join(self.d, f'A{i}'), os.path.join(self.n, f'B{i}'); os.mkdir(A); os.mkdir(B); self.paare.append((A, B))
        self.A, self.B = self.paare[0]; self.p = None
    def start(self, modi=(0,), ergebnis=False):
        self.ids = [str(i) * 32 for i in range(len(self.paare))]
        json.dump([dict(Id=self.ids[i], Name=f'T{i}', A=a, B=b, Mode=modi[i], Exclude='', ExcludeDirs=[], Schedule=None, SchedName='', AutoLnk='') for i, (a, b) in enumerate(self.paare)], open(os.path.join(self.D, 'aufgaben.json'), 'w'))
        json.dump(dict(Theme='dunkel', ShortcutAsked=True, UpdateCheck=False, ShowResult=ergebnis), open(os.path.join(self.D, 'einstellungen.json'), 'w'))
        self.p = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', PS1], env=dict(os.environ, DIRTOY_DATA=self.D), creationflags=0x08000000)
        self.m = wait(self.p.pid, 'DirToy ' + VER); return self.m
    def klick(self, t): mklick(self.m, {'Synchronisieren': 'btnRun', 'Abbrechen': 'btnCancel', 'Vorschau': 'btnPrev', 'Alle Aufgaben ausführen': 'btnAll'}[t])
    def status(self, t, sec=60): return bis(lambda: t == mstatus(self.m), sec, 'Status ' + t)
    def stand(self, i=0):
        f = os.path.join(self.D, 'state', self.ids[i] + '.state'); return set(open(f, encoding='utf-8').read().splitlines()) if os.path.exists(f) else None
    def log(self):
        f = os.path.join(self.D, 'sync.log'); return open(f, encoding='utf-8-sig').read() if os.path.exists(f) else ''
    def tmp(self): return [f for f in dateien(self.d) + (dateien(self.n) if self.n != self.d else []) if f.endswith('.dirtoy-tmp')]
    def zu(self):
        u.PostMessageW(self.m, 0x0010, 0, 0)
    def __enter__(self): return self
    def __exit__(self, *a):
        if os.path.exists(os.path.join(self.D, 'fehler.log')): check('fehler.log: ' + open(os.path.join(self.D, 'fehler.log'), encoding='utf-8-sig').read()[:600], False)
        if self.p and self.p.poll() is None: self.p.kill(); self.p.wait()
        shutil.rmtree(self.d, ignore_errors=True)
        if self.n != self.d: shutil.rmtree(self.n, ignore_errors=True)
def viele(d, n):
    for i in range(n):
        o = os.path.join(d, f'o{i % 10}'); os.makedirs(o, exist_ok=True); open(os.path.join(o, f'f{i:05}.txt'), 'w').write('x' * 2000)
def gross(p, mb):
    b = os.urandom(1 << 20)
    with open(p, 'wb') as f:
        for _ in range(mb): f.write(b)

print('== Abbrechen bei vielen Dateien')
with Lauf() as l:
    viele(l.A, 2500); l.start(); l.klick('Synchronisieren')
    bis(lambda: len(dateien(l.B)) > 60, 30, 'Lauf beginnt')
    check('Abbrechen-Knopf sichtbar, Synchronisieren nicht', knopf_sichtbar(l.m, 'btnCancel') and not knopf_sichtbar(l.m, 'btnRun'))
    l.klick('Abbrechen'); t = l.status('Abgebrochen.', 10); n = dateien(l.B)
    check(f'abgebrochen nach {t:.1f} s bei {len(n)} Dateien', t < 5 * GEDULD and 60 < len(n) < 2500)
    time.sleep(1); check('danach laeuft nichts weiter', dateien(l.B) == n)
    check('keine Zwischendateien', not l.tmp())
    st = {x for x in l.stand() if not x.endswith('\\')}; check('Stand = genau die kopierten Dateien', st == set(n))
    check('Protokoll meldet Abbruch', 'abgebrochen' in l.log())
    l.klick('Synchronisieren'); l.status('Fertig.', 120)
    check('zweiter Lauf: vollstaendig, nichts geloescht', dateien(l.A) == dateien(l.B) and len(dateien(l.A)) == 2500)
    check('Stand vollstaendig', {x for x in l.stand() if not x.endswith('\\')} == set(dateien(l.A)))
    l.zu(); l.p.wait(10)
print('== Abbrechen mitten in einer grossen Datei')
with Lauf() as l:
    gross(os.path.join(l.A, 'gross.bin'), 1400); open(os.path.join(l.B, 'gross.bin'), 'w').write('original'); os.utime(os.path.join(l.B, 'gross.bin'), (1600000000,) * 2)
    l.start(); l.klick('Synchronisieren'); bis(lambda: l.tmp(), 30, 'Zwischendatei'); l.klick('Abbrechen'); t = l.status('Abgebrochen.', 20)
    check(f'nach {t:.1f} s, Original unveraendert', open(os.path.join(l.B, 'gross.bin'), 'rb').read(20) == b'original'); check('keine Zwischendateien', not l.tmp())
    l.zu(); l.p.wait(10)
print('== Schliessen waehrend des Laufs')
with Lauf() as l:
    viele(l.A, 2500); l.start(); l.klick('Synchronisieren'); bis(lambda: len(dateien(l.B)) > 60, 30, 'Lauf beginnt')
    l.zu(); w = wait(l.p.pid, 'DirToy'); click(w, 'Nein'); wait(l.p.pid, 'DirToy', gone=True); time.sleep(0.5)
    check('Nein: Programm laeuft weiter', l.p.poll() is None)
    l.zu(); w = wait(l.p.pid, 'DirToy'); click(w, 'Ja'); t0 = time.time()
    try: l.p.wait(15); check(f'Ja: beendet nach {time.time() - t0:.1f} s', True)
    except subprocess.TimeoutExpired: check('Ja: beendet sich', False)
    check('keine Zwischendateien', not l.tmp()); check('Stand passt zu den Dateien', {x for x in l.stand() if not x.endswith('\\')} == set(dateien(l.B)))
    check('nicht alles kopiert (wirklich abgebrochen)', len(dateien(l.B)) < 2500)
print('== Alle Aufgaben mit Rueckfrage')
with Lauf(3) as l:
    for i in (0, 2): open(os.path.join(l.paare[i][0], 'neu.txt'), 'w').write('x')
    for i in range(20):
        for s in range(2): open(os.path.join(l.paare[1][s], f'b{i}.txt'), 'w').write('x')
    os.utime(os.path.join(l.paare[1][0], 'b0.txt'))
    for i in range(20):
        for s in range(2): os.utime(os.path.join(l.paare[1][s], f'b{i}.txt'), (1700000000,) * 2)
    for i in range(3): os.remove(os.path.join(l.paare[1][0], f'b{i}.txt'))
    l.start((0, 1, 2)); L = 'Löschen bestätigen'
    l.klick('Alle Aufgaben ausführen'); w = wait(l.p.pid, L); check('erste Aufgabe schon fertig', dateien(l.B) == ['neu.txt']); check('dritte wartet', not dateien(l.paare[2][1]))
    time.sleep(1.5); check('wartet auf Antwort', len(dateien(l.paare[1][1])) == 20)
    click(w, 'Nein'); l.status('Alle Aufgaben abgearbeitet.', 20)
    check('Nein: nichts geloescht, dritte gelaufen', len(dateien(l.paare[1][1])) == 20 and dateien(l.paare[2][1]) == ['neu.txt'])
    l.klick('Alle Aufgaben ausführen'); w = wait(l.p.pid, L); click(w, 'Ja'); wait(l.p.pid, L, gone=True); l.status('Alle Aufgaben abgearbeitet.', 20)
    bis(lambda: len(dateien(l.paare[1][1])) == 17, 10, 'Loeschung'); check('Ja: genau 3 geloescht', dateien(l.paare[1][0]) == dateien(l.paare[1][1]))
    l.zu(); l.p.wait(10)
print('== Vorschau veraendert nichts, Ergebnis-Fenster, Fehler')
with Lauf() as l:
    viele(l.A, 50); l.start(ergebnis=True); l.klick('Vorschau'); l.status('Vorschau fertig.'); check('Vorschau: nichts kopiert, kein Stand, kein Protokoll', not dateien(l.B) and l.stand() is None and not l.log())
    k = ctypes.windll.kernel32; k.CreateFileW.restype = ctypes.c_void_p
    h = k.CreateFileW(os.path.join(l.A, 'o0', 'f00000.txt'), 0x80000000, 0, None, 3, 0, None)
    l.klick('Synchronisieren'); w = wait(l.p.pid, 'DirToy - Ergebnis'); check('Ergebnis-Fenster erscheint', True); k.CloseHandle(ctypes.c_void_p(h))
    click(w, 'Schließen'); wait(l.p.pid, 'DirToy - Ergebnis', gone=True)
    check('49 kopiert, gesperrte Datei als Fehler', len(dateien(l.B)) == 49 and '1 Fehler' in l.log() and 'o0\\f00000.txt' not in l.stand())
    l.klick('Synchronisieren'); w = wait(l.p.pid, 'DirToy - Ergebnis'); click(w, 'Schließen'); wait(l.p.pid, 'DirToy - Ergebnis', gone=True); check('zweiter Lauf holt sie nach', dateien(l.A) == dateien(l.B))
    l.zu(); l.p.wait(10)
print('== Ordner im laufenden Betrieb aendern')
with Lauf(2) as l:
    viele(l.A, 1200); falsch = l.paare[1][1]; l.start((0, 0)); l.klick('Synchronisieren'); bis(lambda: len(dateien(l.B)) > 60, 30, 'Lauf beginnt')
    uia('set', l.m, 'tbB', falsch); check('Feld Ordner B geaendert', uia('get', l.m, 'tbB')['value'] == falsch)
    l.status('Fertig.', 60); check('laufender Lauf bleibt beim alten Ordner', len(dateien(l.B)) == 1200 and not dateien(falsch))
    l.zu(); l.p.wait(10)
print('== Reaktion des Fensters waehrend des Laufs')
with Lauf() as l:
    viele(l.A, 2000); gross(os.path.join(l.A, 'gross.bin'), 600); l.start(); l.klick('Synchronisieren'); bis(lambda: dateien(l.B), 30, 'Lauf beginnt'); w = []
    t0 = time.time()
    while len(dateien(l.B)) < 2001 and time.time() - t0 < 60 * GEDULD:
        for _ in range(20): w.append(antwort(l.m)); time.sleep(0.005)
    l.status('Fertig.')
    w.sort(); print(f'   {len(w)} Proben, 99% unter {w[int(len(w) * .99)] * 1000:.0f} ms, laengste {w[-1] * 1000:.0f} ms')
    check('Dateien vollstaendig', dateien(l.A) == dateien(l.B)); l.zu(); l.p.wait(10)
print('ALLES OK' if ok else 'FEHLER')
sys.exit(0 if ok else 1)
