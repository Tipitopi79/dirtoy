# Fenstertest fuer die Bedienung: Aufgaben anlegen, bearbeiten, loeschen; Modus, Zahnrad, Sortieren, Sperren im Lauf, Status in der Liste.
# Start: python tests/test-bedienung.py
import json, os, shutil, subprocess, sys, tempfile, time
from fenster import *
ok = True
def check(n, c):
    global ok
    ok &= bool(c); print('ok ' if c else 'FEHLER', n, flush=True)
d = tempfile.mkdtemp(prefix='dirtoy-bed-'); D, A, B = (os.path.join(d, x) for x in ('daten', 'Quelle', 'Ziel'))
for x in (D, A, B): os.mkdir(x)
json.dump(dict(Theme='hell', ShortcutAsked=True, UpdateCheck=False, ShowResult=False), open(os.path.join(D, 'einstellungen.json'), 'w'))
def auf():
    f = os.path.join(D, 'aufgaben.json')
    if not os.path.exists(f): return []
    r = json.load(open(f, encoding='utf-8-sig')); return r if isinstance(r, list) else [r]
def start():
    p = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', PS1], env=dict(os.environ, DIRTOY_DATA=D), creationflags=0x08000000)
    return p, wait(p.pid, 'DirToy ' + VER)
def zu(p, m): u.PostMessageW(m, 0x0010, 0, 0); p.wait(10)
def st(m, t, sec=30):
    end = time.time() + sec
    while time.time() < end:
        if mstatus(m) == t: return
        time.sleep(.05)
    check('Status ' + t, False); raise SystemExit(1)
def sicht(m, i): r = uia('get', m, i); return r['found'] and r['visible']
def an(m, i): r = uia('get', m, i); return r['found'] and r['enabled']
p, m = start()
try:
    time.sleep(.5); check('erster Start legt eine Aufgabe an', len(auf()) == 1 and auf()[0]['Name'] == 'Aufgabe 1' and auf()[0]['Mode'] == 0)
    uia('set', m, 'tbName', 'Fotos ü'); uia('set', m, 'tbA', A); uia('set', m, 'tbB', B); time.sleep(.3)
    a = auf()[0]; check('Name und Ordner gespeichert', (a['Name'], a['A'], a['B']) == ('Fotos ü', A, B)); check('Karten zeigen Ordnernamen', uia('get', m, 'lblA')['name'] == 'Quelle' and uia('get', m, 'lblB')['name'] == 'Ziel')
    for i in (1, 2, 0, 1): mklick(m, f'm{i}'); time.sleep(.2); check(f'Modus {i} gespeichert', auf()[0]['Mode'] == i)
    check('Erklaerung passt zum Modus', 'exakt wie A' in uia('get', m, 'lblMode')['name'])
    check('Zahnrad zu', not sicht(m, 'tbEx')); mklick(m, 'btnGear'); time.sleep(.3); check('Zahnrad auf', sicht(m, 'tbEx')); uia('set', m, 'tbEx', '*.bak'); time.sleep(.2); check('Ausschluss gespeichert', auf()[0]['Exclude'] == '*.bak')
    mklick(m, 'btnNew'); time.sleep(.4); check('neue Aufgabe', [x['Name'] for x in auf()] == ['Fotos ü', 'Aufgabe 2'] and uia('get', m, 'tbName')['value'] == 'Aufgabe 2'); check('neue Aufgabe hat Modus 0 und leere Ordner', auf()[1]['Mode'] == 0 and uia('get', m, 'tbA')['value'] == '' and auf()[0]['Mode'] == 1)
    id1 = auf()[0]['Id']
    mklick(m, 'btnDel'); w = wait(p.pid, 'Löschen'); click(w, 'Nein'); wait(p.pid, 'Löschen', gone=True); time.sleep(.3); check('Loeschen Nein', len(auf()) == 2)
    mklick(m, 'btnDel'); w = wait(p.pid, 'Löschen'); click(w, 'Ja'); wait(p.pid, 'Löschen', gone=True); time.sleep(.4); check('Loeschen Ja: die richtige weg', [x['Id'] for x in auf()] == [id1]); check('erste Aufgabe gewaehlt', uia('get', m, 'tbName')['value'] == 'Fotos ü')
    zu(p, m); p, m = start(); time.sleep(.4)
    check('nach Neustart alles da', uia('get', m, 'tbName')['value'] == 'Fotos ü' and uia('get', m, 'tbB')['value'] == B and auf()[0]['Exclude'] == '*.bak' and auf()[0]['Mode'] == 1 and auf()[0]['Id'] == id1)
    for n in ('b.txt', 'a.txt', 'c.bak'): open(os.path.join(A, n), 'w').write(n)
    mklick(m, 'btnRun'); st(m, 'Fertig.'); check('Lauf mit Ausschluss', sorted(os.listdir(B)) == ['a.txt', 'b.txt']); check('Knoepfe nach Lauf frei', all(an(m, i) for i in ('btnRun', 'btnPrev', 'btnAll', 'btnNew', 'btnGear', 'btnSched')))
    for i in range(2500): open(os.path.join(A, f'n{i:04}.txt'), 'w').write('x')
    mklick(m, 'btnRun'); time.sleep(1.2); check('im Lauf gesperrt', not any(an(m, i) for i in ('btnPrev', 'btnAll', 'btnNew', 'btnDel', 'btnGear', 'btnSched', 'btnTheme', 'lb')) and sicht(m, 'btnCancel') and not sicht(m, 'btnRun'))
    mklick(m, 'btnCancel'); st(m, 'Abgebrochen.'); check('nach Abbruch frei', an(m, 'btnRun') and sicht(m, 'btnRun') and not sicht(m, 'btnCancel'))
    mklick(m, 'btnRun'); st(m, 'Fertig.', 90); check('Rest kopiert', len(os.listdir(B)) == 2502)
    for h in ('h1', 'h1', 'h0', 'h2'):
        if uia('get', m, h)['found']: mklick(m, h); time.sleep(.2)
    check('Sortieren: Pfeil im Spaltenkopf', uia('get', m, 'h2')['name'][-1:] in '▲▼' and uia('get', m, 'h0')['name'] == 'Aktion')
    mklick(m, 'btnPrev'); st(m, 'Vorschau fertig.'); check('neuer Lauf setzt Sortierung zurueck', uia('get', m, 'h2')['name'] == 'Status')
    uia('set', m, 'tbA', os.path.join(d, 'gibtsnicht')); mklick(m, 'btnRun'); st(m, 'Fertig.'); check('fehlender Ordner: nichts geloescht', len(os.listdir(B)) == 2502)
    zu(p, m); check('kein Fehlerprotokoll', not os.path.exists(os.path.join(D, 'fehler.log')))
finally:
    if p.poll() is None: p.kill(); p.wait()
    if os.path.exists(os.path.join(D, 'fehler.log')): print(open(os.path.join(D, 'fehler.log'), encoding='utf-8-sig').read()[:800])
    shutil.rmtree(d, ignore_errors=True)
print('ALLES OK' if ok else 'FEHLER')
sys.exit(0 if ok else 1)
