# Vollstaendige Vorschau als CSV (Semikolon, UTF-8 mit BOM: oeffnet in Excel mit richtigen Umlauten und Spalten); Rueckgabe: Pfad oder $null
function Write-PreviewFile($t, $plan) {
    try {
        $path = Join-Path $script:dataDir 'vorschau.csv'
        Remove-Item (Join-Path $script:dataDir 'vorschau.txt') -Force -ErrorAction SilentlyContinue
        $sw = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($true)))
        try {
            $sw.WriteLine('Aktion;Ordner;Datei;Relativer Pfad')
            foreach ($p in $plan) {
                $rel = $p.Rel
                $isDir = $rel.EndsWith('\')
                $x = $rel.TrimEnd('\'); $i = $x.LastIndexOf('\')
                $dir = if ($i -ge 0) { $x.Substring(0, $i) } else { '' }
                $name = if ($isDir) { '' } elseif ($i -ge 0) { $x.Substring($i + 1) } else { $x }
                if ($isDir) { $dir = $x }
                $cells = foreach ($c in @($p.Text, $dir, $name, $rel)) {
                    $c = [string]$c
                    if ($c.Length -gt 0 -and '=+-@'.Contains($c[0])) { $c = "'" + $c }   # Excel soll Pfade nie als Formel lesen
                    '"' + $c.Replace('"', '""') + '"'
                }
                $sw.WriteLine($cells -join ';')
            }
        } finally { $sw.Dispose() }
        return $path
    } catch { return $null }
}
