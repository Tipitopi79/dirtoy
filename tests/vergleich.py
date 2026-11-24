# Vergleicht zwei Fassungen von DirToy.ps1: gleiche zufaellige Ordner, gleicher Lauf (-All, wie im Zeitplan).
# Ausgabe, Protokoll, gemerkter Stand und alle Dateien muessen gleich sein.
# Start: python tests/vergleich.py <tag oder pfad alt> [anzahl] [pfad neu]     z. B. v1.7.6 12
import os, random, re, shutil, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
alt = sys.argv[1]; anzahl = int(sys.argv[2]) if len(sys.argv) > 2 else 12
neu = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, 'DirToy.ps1')
tmp = tempfile.mkdtemp(prefix='dirtoy-vgl-', dir=os.environ.get('DIRTOY_TEST_B') or None)
if os.path.exists(alt):
    code_alt = open(alt, 'rb').read()
else:
    code_alt = subprocess.run(['git', '-C', ROOT, 'show', alt + ':DirToy.ps1'], capture_output=True, check=True).stdout
code_neu = open(neu, 'rb').read()
NAMEN = ['a.txt', 'Übung.txt', "o'neil [1].txt", 'x.tmp', 'Thumbs.db', 'gross.bin', 'b c.doc', '$geld.txt']
ORDNER = ['', 'sub', 'sub\\tief', 'Ärger', 'leer', 'weg']

def put(p, txt, t):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8') as f: f.write(txt)
    os.utime(p, (t, t))

def szenario(seed, base):
    r = random.Random(seed); tasks = []; namen = []
    for m in (0, 1, 2):
        A, B = (os.path.join(base, f'm{m}', s) for s in 'AB'); stand = []
        os.makedirs(A); os.makedirs(B)
        for o in ORDNER:
            if r.random() < .3:
                for s in (A, B):
                    if r.random() < .6: os.makedirs(os.path.join(s, o), exist_ok=True)
            for n in NAMEN:
                rel = os.path.join(o, n); w = r.random(); t = 1750000000 + r.randrange(0, 5) * 1000
                if w < .25: continue
                if w < .6: put(os.path.join(A, rel), 'gleich', t); put(os.path.join(B, rel), 'gleich', t)
                elif w < .7: put(os.path.join(A, rel), 'neu', t + 500); put(os.path.join(B, rel), 'alt', t)
                elif w < .78: put(os.path.join(A, rel), 'alt', t); put(os.path.join(B, rel), 'neuer', t + 500)
                elif w < .82: put(os.path.join(A, rel), 'konflikt', t); put(os.path.join(B, rel), 'k', t)
                elif w < .92: put(os.path.join(A, rel), 'nur A', t)
                else: put(os.path.join(B, rel), 'nur B', t)
                if r.random() < .6: stand.append(rel)
            if o and r.random() < .6:
                stand.append(o + '\\')
        # Ordner, der geloescht werden muss (leer, nur noch in B), und einer, der neu ist
        os.makedirs(os.path.join(B, 'alt', 'leer')); stand += ['alt\\', 'alt\\leer\\']
        os.makedirs(os.path.join(A, 'neu', 'leer'))
        i = str(m) * 32
        tasks.append('{"Id":"%s","Name":"T%d","A":%s,"B":%s,"Mode":%d,"Exclude":"Thumbs.db;*.tmp","ExcludeDirs":[%s],"Schedule":{"Notify":2},"SchedName":"","AutoLnk":""}'
                     % (i, m, js(A), js(B), m, js('weg\\') if r.random() < .3 else ''))
        os.makedirs(os.path.join(base, 'daten', 'state'), exist_ok=True)
        if r.random() < .8:
            open(os.path.join(base, 'daten', 'state', i + '.state'), 'w', encoding='utf-8', newline='').write(''.join(x + '\r\n' for x in stand))
    open(os.path.join(base, 'daten', 'aufgaben.json'), 'w', encoding='utf-8').write('[' + ','.join(tasks) + ']')

def js(s):
    import json
    return json.dumps(s)

def bild(base):
    d = {}
    for o, ds, fs in os.walk(base):
        rel = os.path.relpath(o, base)
        d[rel + '\\'] = 'ordner'
        for f in fs:
            p = os.path.join(o, f); b = open(p, 'rb').read()
            if f == 'sync.log':
                b = re.sub(rb'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d', b'ZEIT', b); b = re.sub(rb'DirToy \d+\.\d+\.\d+', b'DirToy V', b)
                b = b.replace(base.encode('utf-8'), b'BASIS')
                d[rel + '\\' + f] = b
            elif f.endswith('.state'):
                d[rel + '\\' + f] = b'\n'.join(sorted(b.splitlines()))
            elif f in ('aufgaben.json',):
                continue
            else:
                d[rel + '\\' + f] = (b, int(os.stat(p).st_mtime))
    return d

def lauf(code, seed, wer):
    base = os.path.join(tmp, f'{wer}'); shutil.rmtree(base, ignore_errors=True); os.makedirs(os.path.join(base, 'p'))
    ps1 = os.path.join(base, 'p', 'DirToy.ps1'); c = code.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'); open(ps1, 'wb').write(c)
    work = os.path.join(base, 'w'); os.makedirs(work); szenario(seed, work)
    e = dict(os.environ, DIRTOY_DATA=os.path.join(work, 'daten'))
    aus = []
    for _ in range(2):   # zweiter Lauf: baut auf dem gemerkten Stand auf
        r = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ps1, '-All'], capture_output=True, env=e, stdin=subprocess.DEVNULL, timeout=120)
        aus.append((r.returncode, r.stdout.replace(work.encode('cp850', 'replace'), b'BASIS'), r.stderr))
    return aus, bild(work)

schlecht = 0; aktionen = 0
try:
    for seed in range(anzahl):
        a1, b1 = lauf(code_alt, seed, 'w1'); a2, b2 = lauf(code_neu, seed, 'w2')
        a2 = [(x, y.replace(b'\\w2\\', b'\\w1\\'), z) for x, y, z in a2]
        u = [k for k in sorted(set(b1) | set(b2)) if b1.get(k) != b2.get(k)]
        n = a1[0][1].count(b'\n'); aktionen += n
        if a1 != a2 or u:
            schlecht += 1; print(f'Szenario {seed}: UNTERSCHIED Ausgabe={a1 != a2} Dateien={u[:5]}')
        else:
            print(f'Szenario {seed}: gleich ({n} Zeilen, Exitcodes {a1[0][0]}/{a1[1][0]})')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f'{schlecht} Unterschiede, {aktionen} Ausgabezeilen verglichen')
sys.exit(1 if schlecht or not aktionen else 0)
