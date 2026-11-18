# Erzeugt DirToy.ico (mehrere Groessen) und gibt das 64-px-PNG als Base64 aus (fuer den Einbau in DirToy.ps1).
# Aufruf: powershell -NoProfile -File tools\make-icon.ps1
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

function New-IconBitmap([int]$size) {
    $s = 512                                   # grosse Zeichenflaeche, dann herunterskaliert (glatte Kanten)
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)

    # Ordner-Form (Reiter links oben) als Pfad
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 56
    $x0 = 36; $x1 = 476; $yTab = 76; $yBody = 148; $y1 = 440; $tabW = 190
    $p.AddArc($x0, $yTab, $r, $r, 180, 90)                       # links oben (Reiter)
    $p.AddLine($x0 + $r / 2, $yTab, $x0 + $tabW - 30, $yTab)
    $p.AddLine($x0 + $tabW - 30, $yTab, $x0 + $tabW + 20, $yBody)  # schraege Flanke zum Koerper
    $p.AddLine($x0 + $tabW + 20, $yBody, $x1 - $r / 2, $yBody)
    $p.AddArc($x1 - $r, $yBody, $r, $r, 270, 90)
    $p.AddArc($x1 - $r, $y1 - $r, $r, $r, 0, 90)
    $p.AddArc($x0, $y1 - $r, $r, $r, 90, 90)
    $p.CloseFigure()
    $rect = New-Object System.Drawing.Rectangle 0, 60, 512, 400
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.ColorTranslator]::FromHtml('#4CC2FF')), ([System.Drawing.ColorTranslator]::FromHtml('#0067C0')), 60
    $g.FillPath($grad, $p)

    # zwei Sync-Pfeile (oben nach rechts, unten nach links)
    $white = [System.Drawing.Color]::White
    $pen = New-Object System.Drawing.Pen $white, 34
    $pen.StartCap = 'Round'; $pen.EndCap = 'Flat'
    $b = New-Object System.Drawing.SolidBrush $white
    $g.DrawLine($pen, 140, 262, 330, 262)
    $g.FillPolygon($b, [System.Drawing.Point[]]@((New-Object System.Drawing.Point 320, 200), (New-Object System.Drawing.Point 400, 262), (New-Object System.Drawing.Point 320, 324)))
    $g.DrawLine($pen, 372, 354, 182, 354)
    $g.FillPolygon($b, [System.Drawing.Point[]]@((New-Object System.Drawing.Point 192, 292), (New-Object System.Drawing.Point 112, 354), (New-Object System.Drawing.Point 192, 416)))
    $g.Dispose()

    $out = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = 'HighQualityBicubic'; $g2.SmoothingMode = 'HighQuality'; $g2.PixelOffsetMode = 'HighQuality'
    $g2.DrawImage($bmp, 0, 0, $size, $size); $g2.Dispose(); $bmp.Dispose()
    return $out
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @{}
foreach ($sz in $sizes) {
    $bm = New-IconBitmap $sz
    $ms = New-Object System.IO.MemoryStream; $bm.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $pngs[$sz] = $ms.ToArray(); $bm.Dispose()
}
# ICO-Datei mit PNG-Eintraegen (ab Windows Vista ueblich)
$fs = [System.IO.File]::Create((Join-Path $root 'DirToy.ico'))
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($sz in $sizes) {
    $wb = if ($sz -ge 256) { 0 } else { $sz }
    $bw.Write([byte]$wb); $bw.Write([byte]$wb); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$sz].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$sz].Length
}
foreach ($sz in $sizes) { $bw.Write($pngs[$sz]) }
$bw.Dispose(); $fs.Dispose()
[System.IO.File]::WriteAllBytes((Join-Path $env:TEMP 'dirtoy-icon-256.png'), $pngs[256])
[Convert]::ToBase64String($pngs[64]) | Set-Content (Join-Path $env:TEMP 'dirtoy-icon-64.b64') -Encoding ASCII
"DirToy.ico geschrieben; Vorschau: $env:TEMP\dirtoy-icon-256.png; Base64 (64 px): $env:TEMP\dirtoy-icon-64.b64"
