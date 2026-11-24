# Fenstertest fuer die Dialoge: Zeitplan, Anleitung, Hilfe, Ergebnis, Ordnerbaum, Update. Legt keine echten Windows-Aufgaben an
# (Register-Sched/Unregister-Sched und die Update-Abfrage sind in einer Kopie ersetzt).
# Start: python tests/test-dialoge.py [--bilder <ordner>]
import json, os, shutil, subprocess, sys, tempfile, time
from fenster import *
ok = True
def check(n, c):
    global ok
    ok &= bool(c); print('ok ' if c else 'FEHLER', n, flush=True)
d = tempfile.mkdtemp(prefix='dirtoy-dlg-'); D, A, B, DESK, AUTO = (os.path.join(d, x) for x in ('daten', 'A', 'B', 'desk', 'auto'))
for x in (D, A, B, DESK, AUTO): os.mkdir(x)
src = open(PS1, encoding='utf-8-sig', newline='').read()
def ers(a, b):
    global src
    assert src.count(a) == 1, (a, src.count(a)); src = src.replace(a, a + b)
ers('function Register-Sched($t, $s) {', "\r\n    if (Test-Path (Join-Path $script:dataDir 'verbieten')) { throw 'Zugriff verweigert (Test)' }\r\n    $t.SchedName = 'DirToy - Test'; $t.Schedule = $s; return")
ers('function Unregister-Sched($t) {', "\r\n    $t.SchedName = ''; return")
ers('function Get-SchedInfo($t) {', "\r\n    if ($t.SchedName) { return [pscustomobject]@{ State = 'Ready'; Next = [datetime]'2030-01-02 03:04'; Last = $null; Result = 0 } } else { return $null }")
ers('function Start-UpdateCheck([bool]$manual) {', "\r\n    if ($manual) { $script:updT = Show-UpdateDialog ([pscustomobject]@{ Version = [version]'9.9.9'; Notes = 'Testnotiz'; Url = 'x'; Tag = 'v9.9.9' }) 'new'; [IO.File]::WriteAllText((Join-Path $script:dataDir 'upd.txt'), [string]$script:updT) }; return")
ps1 = os.path.join(d, 'DirToy.ps1'); open(ps1, 'w', encoding='utf-8-sig', newline='').write(src)
theme = os.environ.get('DIRTOY_TEST_DESIGN', 'dunkel')
json.dump(dict(Theme=theme, ShortcutAsked=True, UpdateCheck=False, ShowResult=True), open(os.path.join(D, 'einstellungen.json'), 'w'))
ID = 'b' * 32
def schreib(**kw):
    t = dict(Id=ID, Name='Test & <Ü>', A=A, B=B, Mode=1, Exclude='*.bak;muster', ExcludeDirs=[], Schedule=None, SchedName='', AutoLnk=''); t.update(kw)
    json.dump([t], open(os.path.join(D, 'aufgaben.json'), 'w'))
def auf():
    r = json.load(open(os.path.join(D, 'aufgaben.json'), encoding='utf-8-sig')); return (r if isinstance(r, list) else [r])[0]
def einst(): return json.load(open(os.path.join(D, 'einstellungen.json'), encoding='utf-8-sig'))
def start():
    p = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ps1], env=dict(os.environ, DIRTOY_DATA=D, DIRTOY_DESKTOP=DESK, DIRTOY_STARTUP=AUTO), creationflags=0x08000000)
    return p, wait(p.pid, 'DirToy ' + VER)
def zu(p, m): u.PostMessageW(m, 0x0010, 0, 0); p.wait(10)
def weg(t): wait(p.pid, t, gone=True); time.sleep(.3)
def auf_dlg(id, t): mklick(m, id); return wait(p.pid, t)
def g(h, i): return uia('get', h, i)
def sicht(h, i): r = g(h, i); return r['found'] and r['visible']
def nachricht(titel, enthaelt, knopf):
    w = wait(p.pid, titel) if titel != 'Zeitplan' else zweites(titel)
    r = enthaelt in g(w, 'msgText').get('name', '')
    if not r: print('   Meldung war:', g(w, 'msgText').get('name', ''))
    click(w, knopf); end = time.time() + 10
    while time.time() < end and u.IsWindow(w): time.sleep(.05)
    time.sleep(.3); return r
def zweites(titel):   # Meldung mit gleichem Titel wie der Dialog darunter
    end = time.time() + 10
    while time.time() < end:
        for h in tops(p.pid):
            if text(h) == titel and g(h, 'msgText')['found']: time.sleep(.3); return h
        time.sleep(.1)
    raise SystemExit('keine Meldung ' + titel)
schreib(); p, m = start()
try:
    print('== Zeitplan')
    w = auf_dlg('btnSched', 'Zeitplan'); shot(w, f'd-zeitplan-{theme}.png')
    check('Vorgaben', g(w, 't0')['on'] and g(w, 'n1')['on'] and g(w, 'time')['value'] == '22:00' and 'Test & <Ü>' in g(w, 'head')['name'])
    check('Taeglich: Wochentage und Intervall versteckt', not sicht(w, 'd0') and not sicht(w, 'min') and sicht(w, 'rep') and not g(w, 'repMin')['enabled'])
    mklick(w, 't2'); time.sleep(.2); check('Intervall sichtbar, Startzeit = jetzt', sicht(w, 'min') and not sicht(w, 'rep') and abs(int(g(w, 'time')['value'][:2]) * 60 + int(g(w, 'time')['value'][3:]) - time.localtime().tm_hour * 60 - time.localtime().tm_min) in (0, 1, 1439, 1438))
    mklick(w, 't3'); time.sleep(.2); check('Anmeldung: keine Uhrzeit', not sicht(w, 'time'))
    mklick(w, 't0'); uia('set', w, 'time', '25:99'); click(w, 'Aktivieren'); check('falsche Uhrzeit abgelehnt', nachricht('Zeitplan', 'Uhrzeit', 'OK') and not auf()['SchedName'])
    mklick(w, 't1'); uia('set', w, 'time', '7:05'); time.sleep(.2)
    for k in range(5): mklick(w, f'd{k}')
    click(w, 'Aktivieren'); check('ohne Wochentag abgelehnt', nachricht('Zeitplan', 'Wochentag', 'OK') and not auf()['SchedName'])
    mklick(w, 'd2'); mklick(w, 'd6'); uia('set', w, 'time', '7:05'); mklick(w, 'rep'); uia('set', w, 'repMin', '90'); uia('set', w, 'repHr', '1')
    click(w, 'Aktivieren'); check('Intervall laenger als Zeitraum abgelehnt', nachricht('Zeitplan', 'nicht länger', 'OK'))
    uia('set', w, 'repMin', 'abc'); click(w, 'Aktivieren'); check('Text statt Zahl abgelehnt', nachricht('Zeitplan', '1440', 'OK'))
    uia('set', w, 'repMin', '15'); uia('set', w, 'repHr', '3'); mklick(w, 'n2'); click(w, 'Aktivieren'); weg('Zeitplan')
    s = auf()['Schedule']; check('woechentlich gespeichert', (s['Type'], s['Time'], s['Days'], s['Repeat'], s['RepMinutes'], s['RepHours'], s['Notify'], s['Start2']) == (1, '07:05', ['Wednesday', 'Sunday'], True, 15, 3, 2, False)); check('Anzeige oben rechts', 'wöchentlich Mi,So um 07:05' in g(m, 'lblSched')['name'])
    w = auf_dlg('btnSched', 'Zeitplan'); check('beim Oeffnen geladen', g(w, 't1')['on'] and g(w, 'time')['value'] == '07:05' and [g(w, f'd{k}')['on'] for k in range(7)] == [False, False, True, False, False, False, True] and g(w, 'rep')['on'] and g(w, 'repMin')['value'] == '15' and g(w, 'n2')['on'])
    mklick(w, 't2'); time.sleep(.2); uia('set', w, 'min', '0'); click(w, 'Speichern'); check('Intervall 0 abgelehnt', nachricht('Zeitplan', '1440', 'OK')); uia('set', w, 'min', '45'); uia('set', w, 'time', '06:00'); click(w, 'Speichern'); weg('Zeitplan')
    s = auf()['Schedule']; check('Intervall gespeichert', (s['Type'], s['Minutes'], s['Time'], s['Start2'], s['Repeat']) == (2, 45, '06:00', True, False))
    w = auf_dlg('btnSched', 'Zeitplan'); mklick(w, 't3'); click(w, 'Abbrechen'); weg('Zeitplan'); check('Abbrechen aendert nichts', auf()['Schedule']['Type'] == 2)
    w = auf_dlg('btnSched', 'Zeitplan'); click(w, 'Zeitplan entfernen'); weg('Zeitplan'); check('entfernt', auf()['Schedule'] is None and auf()['SchedName'] == '' and g(m, 'lblSched')['name'] == 'Kein Zeitplan')
    print('== Anleitung von Hand')
    open(os.path.join(D, 'verbieten'), 'w').close(); w = auf_dlg('btnSched', 'Zeitplan'); click(w, 'Aktivieren'); w2 = wait(p.pid, 'Zeitplan von Hand anlegen'); shot(w2, f'd-anleitung-{theme}.png')
    t = g(w2, 'tb')['value']; check('Anleitung nennt Grund und Befehl', 'Zugriff verweigert (Test)' in t and ID in t); check('nichts eingetragen', auf()['Schedule'] is None)
    click(w2, 'Beim Anmelden starten'); check('Autostart-Eintrag', nachricht('DirToy', 'Eingerichtet', 'OK') and len(os.listdir(AUTO)) == 1 and auf()['AutoLnk'])
    click(w2, 'Schließen'); weg('Zeitplan von Hand anlegen'); click(w, 'Abbrechen'); weg('Zeitplan'); os.remove(os.path.join(D, 'verbieten'))
    print('== Hilfe')
    w = auf_dlg('btnHelp', 'DirToy - Hilfe'); shot(w, f'd-hilfe-{theme}.png'); check('Haken Ergebnis an', g(w, 'showRes')['on']); mklick(w, 'showRes'); time.sleep(.2); check('ausgeschaltet gespeichert', einst()['ShowResult'] is False); mklick(w, 'showRes'); time.sleep(.2); check('wieder an', einst()['ShowResult'] is True)
    click(w, 'Desktop-Verknüpfung'); check('Verknuepfung', nachricht('DirToy', 'Desktop angelegt', 'OK') and os.listdir(DESK) == ['DirToy.lnk']); click(w, 'Schließen'); weg('DirToy - Hilfe')
    print('== Update')
    w = auf_dlg('lblVer', 'DirToy - Update'); shot(w, f'd-update-{theme}.png'); check('Version und Notizen', '9.9.9' in g(w, 'head')['name'] and g(w, 'notes')['value'] == 'Testnotiz' and not g(w, 'auto')['on']); mklick(w, 'auto'); click(w, 'Später'); weg('DirToy - Update'); check('Spaeter: keine Aktion, Haken gespeichert', open(os.path.join(D, 'upd.txt')).read() == '' and einst()['UpdateCheck'] is True)
    w = auf_dlg('lblVer', 'DirToy - Update'); click(w, 'Jetzt aktualisieren'); weg('DirToy - Update'); check('Aktualisieren gemeldet', open(os.path.join(D, 'upd.txt')).read() == 'install')
    print('== Ordnerbaum')
    for r in (A, B):
        for o in ('eins', 'eins\\tief', 'zwei', 'muster'): os.makedirs(os.path.join(r, o), exist_ok=True)
        for o in ('eins', 'eins\\tief', 'zwei'): open(os.path.join(r, o, 'x.txt'), 'w').write('x'); os.utime(os.path.join(r, o, 'x.txt'), (1700000000,) * 2)
    zu(p, m); schreib(ExcludeDirs=['fehlt\\']); p, m = start(); mklick(m, 'btnGear'); time.sleep(.4)
    check('Zahl am Knopf', '(1)' in g(m, 'btnDirs')['name'])
    def baum(): return auf_dlg('btnDirs', 'Ordner auswählen')
    def kn(n, ix=0): return uia('get', w, n, byname=True, index=ix)
    w = baum(); shot(w, f'd-baum-{theme}.png'); check('Haken richtig', kn('eins')['on'] and kn('zwei')['on'] and not kn('muster   (durch Muster ausgeschlossen)')['on'] and not kn('fehlt   (nicht vorhanden)')['on'])
    click(w, 'zwei'); time.sleep(.3); check('abwaehlen gilt fuer beide Seiten', not kn('zwei')['on'] and not kn('zwei', 1)['on'] and '2 Ordner' in g(w, 'count')['name'])
    click(w, 'muster   (durch Muster ausgeschlossen)'); time.sleep(.3); check('Muster laesst sich nicht anhaken', not kn('muster   (durch Muster ausgeschlossen)')['on'] and 'Muster' in g(w, 'hint')['name'])
    uia('expand', w, 'eins', byname=True); time.sleep(.4); check('Unterordner geladen', kn('tief')['found'] and kn('tief')['on'])
    click(w, 'eins'); time.sleep(.3); check('Unterordner mit abgewaehlt', not kn('tief')['on']); click(w, 'tief'); time.sleep(.3); check('Unterordner allein nicht anhakbar', not kn('tief')['on'] and 'übergeordneter' in g(w, 'hint')['name'])
    click(w, 'fehlt   (nicht vorhanden)'); time.sleep(.3); check('nicht vorhandener verschwindet beidseitig', not kn('fehlt   (nicht vorhanden)')['found'])
    click(w, 'OK'); weg('Ordner auswählen'); check('gespeichert', auf()['ExcludeDirs'] == ['eins\\', 'zwei\\'] and '(2)' in g(m, 'btnDirs')['name'])
    w = baum(); click(w, 'zwei'); click(w, 'Abbrechen'); weg('Ordner auswählen'); check('Abbrechen aendert nichts', auf()['ExcludeDirs'] == ['eins\\', 'zwei\\'])
    w = baum(); click(w, 'Alle wieder einschließen'); time.sleep(.3); check('alle an', kn('eins')['on'] and kn('zwei')['on']); click(w, 'zwei'); click(w, 'OK'); weg('Ordner auswählen'); check('nur zwei abgewaehlt', auf()['ExcludeDirs'] == ['zwei\\'])
    print('== Ergebnis und Wirkung der Auswahl')
    open(os.path.join(A, 'eins', 'neu.txt'), 'w').write('n'); open(os.path.join(A, 'zwei', 'nicht.txt'), 'w').write('n'); open(os.path.join(A, 'eins', 'a&b.txt'), 'w').write('n')
    w = auf_dlg('btnRun', 'DirToy - Ergebnis'); shot(w, f'd-ergebnis-{theme}.png'); check('abgewaehlter Ordner nicht angefasst', not os.path.exists(os.path.join(B, 'zwei', 'nicht.txt')) and os.path.exists(os.path.join(B, 'eins', 'neu.txt'))); check('Titel', 'Test & <Ü>' in g(w, 'head')['name'])
    click(w, 'Schließen'); weg('DirToy - Ergebnis')
    print('== Echte Loeschfrage, Esc')
    os.remove(os.path.join(A, 'eins', 'neu.txt')); L = 'Löschen bestätigen'
    mklick(m, 'btnRun'); w = wait(p.pid, L); shot(w, f'd-loeschen-{theme}.png'); u.PostMessageW(w, 0x0010, 0, 0); weg(L); time.sleep(.5); check('X = nicht loeschen', os.path.exists(os.path.join(B, 'eins', 'neu.txt')))
    time.sleep(.5); mklick(m, 'btnRun'); w = wait(p.pid, L); click(w, 'Ja'); weg(L); w = wait(p.pid, 'DirToy - Ergebnis'); check('Ja = geloescht', not os.path.exists(os.path.join(B, 'eins', 'neu.txt'))); click(w, 'Schließen'); weg('DirToy - Ergebnis')
    zu(p, m); check('kein Fehlerprotokoll', not os.path.exists(os.path.join(D, 'fehler.log')))
finally:
    if p.poll() is None: p.kill(); p.wait()
    if os.path.exists(os.path.join(D, 'fehler.log')): print(open(os.path.join(D, 'fehler.log'), encoding='utf-8-sig').read()[:800])
    shutil.rmtree(d, ignore_errors=True)
print('ALLES OK' if ok else 'FEHLER')
sys.exit(0 if ok else 1)
