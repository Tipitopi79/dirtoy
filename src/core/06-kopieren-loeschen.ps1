# ---------------------------------------------------------------- Plan ausführen
function Copy-One($src, $dst) {
    $dir = [System.IO.Path]::GetDirectoryName($dst)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Sicher kopieren: erst in eine Zwischendatei schreiben, erst wenn sie komplett ist an die Stelle des Ziels setzen.
    # Bei Abbruch/Absturz bleibt das Original im Ziel unveraendert.
    $tmp = $dst + $script:tmpSuffix
    $in = $null; $out = $null; $ok = $false
    try {
        $in = New-Object System.IO.FileStream($src, 'Open', 'Read', 'ReadWrite')
        $out = New-Object System.IO.FileStream($tmp, 'Create', 'Write', 'None')
        if (-not $script:copyBuf) { $script:copyBuf = New-Object byte[] (4MB) }
        $total = $in.Length; $done = 0; $last = [Environment]::TickCount
        while (($n = $in.Read($script:copyBuf, 0, $script:copyBuf.Length)) -gt 0) {
            $out.Write($script:copyBuf, 0, $n); $done += $n
            if (Test-Cancel) { throw 'DIRTOY_CANCEL' }
            if (([Environment]::TickCount - $last) -ge $script:pumpMs) {
                $last = [Environment]::TickCount
                if ($total -gt 8MB) { Out-Status "Kopiere $([System.IO.Path]::GetFileName($src)): $([int](100 * $done / $total)) %" }
                Pump
            }
        }
        $out.Dispose(); $out = $null; $in.Dispose(); $in = $null
        $attr = [System.IO.File]::GetAttributes($src)
        $utc = [System.IO.File]::GetLastWriteTimeUtc($src)
        [System.IO.File]::SetLastWriteTimeUtc($tmp, $utc)
        if (Test-Path -LiteralPath $dst) {
            [System.IO.File]::SetAttributes($dst, [System.IO.FileAttributes]::Normal)
            try { [System.IO.File]::Replace($tmp, $dst, $null) }
            catch { [System.IO.File]::Delete($dst); [System.IO.File]::Move($tmp, $dst) }
        } else {
            [System.IO.File]::Move($tmp, $dst)
        }
        $ok = $true
        try { [System.IO.File]::SetLastWriteTimeUtc($dst, $utc); [System.IO.File]::SetAttributes($dst, $attr) } catch { }
    } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        if (-not $ok) { try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } } catch { } }
    }
}
# In den Papierkorb (wo es keinen gibt, z. B. Netzlaufwerk: endgueltig). Nie ein Windows-Fenster: ein Fehlerfenster
# wuerde den Lauf anhalten, bis jemand klickt (bei Zeitplaenen unbemerkt). Fehler werden zur Ausnahme -> Protokoll.
# Alles steht in der Funktion: der Sync-Thread bekommt nur Funktionen mit, keine Skript-Variablen.
function Delete-One($path, [int]$flags = 0x0654) {   # FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR | FOF_NOERRORUI
    if (-not ('DirToyShell.Papierkorb' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace DirToyShell {
    public static class Papierkorb {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Op64 { public IntPtr hwnd; public uint wFunc; public string pFrom; public string pTo; public ushort fFlags; public int fAborted; public IntPtr hMaps; public string title; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 1)]
        struct Op32 { public IntPtr hwnd; public uint wFunc; public string pFrom; public string pTo; public ushort fFlags; public int fAborted; public IntPtr hMaps; public string title; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperationW(ref Op64 op);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperationW(ref Op32 op);
        // Rueckgabe: Fehlercode (0 = ok), aborted: Windows hat abgebrochen
        public static int Delete(string path, int flags, out bool aborted) {
            int r;
            if (IntPtr.Size == 8) { var o = new Op64(); o.wFunc = 3; o.pFrom = path + "\0\0"; o.fFlags = (ushort)flags; r = SHFileOperationW(ref o); aborted = o.fAborted != 0; }
            else { var o = new Op32(); o.wFunc = 3; o.pFrom = path + "\0\0"; o.fFlags = (ushort)flags; r = SHFileOperationW(ref o); aborted = o.fAborted != 0; }
            return r;
        }
    }
}
'@
    }
    $aborted = $false
    $r = [DirToyShell.Papierkorb]::Delete([System.IO.Path]::GetFullPath($path), $flags, [ref]$aborted)
    if ($r -ne 0) {
        $m = if ($r -lt 0x71 -or $r -gt 0x10000) { (New-Object System.ComponentModel.Win32Exception($r)).Message } else { 'Windows konnte die Datei nicht löschen' }
        throw ('{0} (Code 0x{1:X})' -f $m, $r)
    }
    if ($aborted) { throw 'Windows hat das Löschen abgebrochen' }
}
# Neuer Zustand aus dem Ergebnis des Laufs (kein erneutes Einlesen: ein anderer PC, der waehrenddessen
# im selben Ordner loescht, wuerde sonst die Liste verfaelschen und Geloeschtes kaeme zurueck).
# Erfolgreich kopiert/angelegt -> jetzt auf beiden Seiten. Fehlgeschlagen, uebersprungen oder durch Abbruch
# nicht mehr ausgefuehrt -> bleibt auf dem alten Stand, damit der naechste Lauf es richtig wiederholt.
function Save-RunState($t, $r, [bool[]]$ok) {
    $set = New-DirSet
    $set.UnionWith($r.Both)
    $plan = $r.Plan
    for ($j = 0; $j -lt $plan.Count; $j++) {
        $p = $plan[$j]
        if ($ok -and $ok[$j]) {
            switch ($p.Typ) {
                'Copy'  {
                    [void]$set.Add($p.Rel)
                    $parts = $p.Rel.Split('\'); $acc = ''
                    for ($k = 0; $k -lt $parts.Length - 1; $k++) { $acc += $parts[$k] + '\'; [void]$set.Add($acc) }
                }
                'MkDir' { [void]$set.Add($p.Rel) }
                default { [void]$set.Remove($p.Rel) }   # Delete/RmDir: jetzt auf keiner Seite mehr
            }
        } elseif ($r.State.Contains($p.Rel)) { [void]$set.Add($p.Rel) }
    }
    Save-State $t.Id $set
}

