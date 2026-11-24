# ---- Ordnerbaum-Fenster: Ordner abwaehlen, die nicht synchronisiert werden sollen
function Get-ParentPath([string]$p) {
    $x = $p.TrimEnd('\'); $i = $x.LastIndexOf('\')
    if ($i -lt 0) { return '' } else { return $x.Substring(0, $i + 1) }
}
function Test-ExistsAny([string]$rel) {
    return ([System.IO.Directory]::Exists((Join-Path $script:fdRootA $rel)) -or [System.IO.Directory]::Exists((Join-Path $script:fdRootB $rel)))
}
function Test-EffExcluded([string]$path) {
    foreach ($x in $script:fdSet) { if ($path.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function Test-AncExcluded([string]$path) {
    foreach ($x in $script:fdSet) { if ($path.Length -gt $x.Length -and $path.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function New-TreeNodeFor([string]$text, [string]$path, [string]$kind, [string]$root) {
    $n = New-Object System.Windows.Forms.TreeNode($text)
    $n.Tag = @{ Path = $path; Kind = $kind; Root = $root; Loaded = ($kind -ne 'normal') }
    if ($kind -eq 'normal') { [void]$n.Nodes.Add((New-Object System.Windows.Forms.TreeNode('...'))) }   # Platzhalter fuer Pfeil
    return $n
}
function Fill-Nodes($coll, [string]$parentPath, [string]$root) {
    $coll.Clear()
    $abs = Join-Path $root $parentPath
    try { $dirs = @((New-Object System.IO.DirectoryInfo $abs).GetDirectories() | Sort-Object Name) } catch { $dirs = @() }
    foreach ($d in $dirs) {
        if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $p = $parentPath + $d.Name + '\'
        if (Test-Excluded $d.Name $script:fdPats) { [void]$coll.Add((New-TreeNodeFor ($d.Name + '   (durch Muster ausgeschlossen)') $p 'pattern' $root)) }
        else { [void]$coll.Add((New-TreeNodeFor $d.Name $p 'normal' $root)) }
    }
    # abgewaehlte Ordner, die es nirgends mehr gibt
    foreach ($x in @($script:fdSet | Sort-Object)) {
        if (Test-ExistsAny $x) { continue }
        $par = Get-ParentPath $x
        $orphan = ($par -ne '') -and -not (Test-ExistsAny $par)
        if ($parentPath -eq '' -and $orphan) { [void]$coll.Add((New-TreeNodeFor ($x.TrimEnd('\') + '   (nicht vorhanden)') $x 'missing' $root)) }
        elseif ($par -eq $parentPath -and -not $orphan) {
            $name = $x.TrimEnd('\').Substring($par.Length)
            [void]$coll.Add((New-TreeNodeFor ($name + '   (nicht vorhanden)') $x 'missing' $root))
        }
    }
}
function Update-TreeChecks($nodes) {
    foreach ($n in $nodes) {
        $tag = $n.Tag
        if ($null -eq $tag) { continue }
        $excl = ($tag.Kind -ne 'normal') -or (Test-EffExcluded $tag.Path)
        $n.Checked = -not $excl
        $n.ForeColor = $(if ($excl) { $th.Muted } else { $th.Text })
        if ($tag.Loaded -and $n.Nodes.Count -gt 0) { Update-TreeChecks $n.Nodes }
    }
}
function Refresh-Trees {
    $script:fdUpdating = $true
    try { foreach ($tv in @($script:fdTvA, $script:fdTvB)) { Update-TreeChecks $tv.Nodes } }
    finally { $script:fdUpdating = $false }
    $script:fdCount.Text = "$($script:fdSet.Count) Ordner abgewählt"
}
function Remove-MissingIn($coll, [string]$path) {
    for ($i = $coll.Count - 1; $i -ge 0; $i--) {
        $n = $coll[$i]; $tag = $n.Tag
        if ($null -eq $tag) { continue }
        if ($tag.Kind -eq 'missing' -and $tag.Path -ieq $path) { $coll.RemoveAt($i) }
        elseif ($tag.Loaded -and $n.Nodes.Count -gt 0) { Remove-MissingIn $n.Nodes $path }
    }
}
function Show-FolderDialog($t) {
    try {
        $script:fdRootA = [System.IO.Path]::GetFullPath([string]$t.A).TrimEnd('\')
        $script:fdRootB = [System.IO.Path]::GetFullPath([string]$t.B).TrimEnd('\')
    } catch { $script:fdRootA = ''; $script:fdRootB = '' }
    if (-not $t.A -or -not $t.B -or -not (Test-Path -LiteralPath $script:fdRootA -PathType Container) -or -not (Test-Path -LiteralPath $script:fdRootB -PathType Container)) {
        [void](Show-Msg ('Bitte zuerst Ordner A und Ordner B angeben (beide müssen existieren).') 'Ordner wählen')
        return
    }
    $script:fdTask = $t
    $script:fdPats = Get-Patterns $t
    $script:fdSet = Get-ExcludeDirs $t
    $script:fdUpdating = $false

    $d = New-Object System.Windows.Forms.Form
    $script:fdForm = $d
    $d.Text = 'Ordner auswählen'; $d.ClientSize = New-Object System.Drawing.Size(1000, 680); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $h = New-Object System.Windows.Forms.Label; $h.Text = 'Ordner auswählen'; $h.Font = $fBold; $h.AutoSize = $false; $h.TextAlign = 'MiddleLeft'
    [void](Add-To $d $h 20 12 700 28)
    [void](New-Label $d 20 40 960 'Haken entfernen = Ordner samt Unterordnern wird nicht synchronisiert. Neue Ordner sind standardmäßig dabei (Haken gesetzt).' $true)
    [void](New-Label $d 20 76 470 ('A:  ' + $script:fdRootA) $true)
    [void](New-Label $d 510 76 470 ('B:  ' + $script:fdRootB) $true)
    $mk = {
        param($x)
        $tv = New-Object System.Windows.Forms.TreeView
        $tv.CheckBoxes = $true; $tv.BorderStyle = 'FixedSingle'; $tv.BackColor = $th.Input; $tv.ForeColor = $th.Text; $tv.Font = $fNormal
        $tv.ShowLines = $true; $tv.ItemHeight = 24; $tv.HideSelection = $false
        [void](Add-To $d $tv $x 100 470 470)
        return $tv
    }
    $script:fdTvA = & $mk 20
    $script:fdTvB = & $mk 510
    $script:fdHint = New-Label $d 20 580 960 '' $true
    $script:fdCount = New-Label $d 20 604 500 '' $true
    $bAll = New-Btn $d 20 634 210 34 'Alle wieder einschließen' $false $th.Surface
    $bOk = New-Btn $d 770 634 100 34 'OK' $true $null
    $bCancel = New-Btn $d 880 634 100 34 'Abbrechen' $false $th.Surface

    $expand = {
        param($s, $e)
        $tag = $e.Node.Tag
        if ($null -ne $tag -and -not $tag.Loaded) {
            $tag.Loaded = $true
            Fill-Nodes $e.Node.Nodes $tag.Path $tag.Root
            Refresh-Trees
        }
    }
    $script:fdTvA.Add_BeforeExpand($expand); $script:fdTvB.Add_BeforeExpand($expand)
    $checked = {
        param($s, $e)
        if ($script:fdUpdating) { return }
        $n = $e.Node; $tag = $n.Tag
        if ($null -eq $tag) { return }
        $script:fdHint.Text = ''
        $revert = $false
        if ($tag.Kind -eq 'pattern') { $revert = $true; $script:fdHint.Text = 'Dieser Ordner ist durch ein Muster im Ausschlussfeld ausgeschlossen.' }
        elseif ($n.Checked -and (Test-AncExcluded $tag.Path)) { $revert = $true; $script:fdHint.Text = 'Ein übergeordneter Ordner ist abgewählt. Dort zuerst den Haken wieder setzen.' }
        if ($revert) { $script:fdUpdating = $true; $n.Checked = -not $n.Checked; $script:fdUpdating = $false; return }
        if ($n.Checked) {
            [void]$script:fdSet.Remove($tag.Path)
            if ($tag.Kind -eq 'missing') { Remove-MissingIn $script:fdTvA.Nodes $tag.Path; Remove-MissingIn $script:fdTvB.Nodes $tag.Path }
        } else { [void]$script:fdSet.Add($tag.Path) }
        Refresh-Trees
    }
    $script:fdTvA.Add_AfterCheck($checked); $script:fdTvB.Add_AfterCheck($checked)
    $bAll.Add_Click({
        $script:fdSet.Clear()
        Fill-Nodes $script:fdTvA.Nodes '' $script:fdRootA; Fill-Nodes $script:fdTvB.Nodes '' $script:fdRootB
        Refresh-Trees
    })
    $bOk.Add_Click({
        $script:fdTask.ExcludeDirs = [string[]]@($script:fdSet | Sort-Object)
        Save-Tasks
        $script:fdForm.DialogResult = 'OK'
    })
    $bCancel.Add_Click({ $script:fdForm.DialogResult = 'Cancel' })
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:fdForm.Handle, 20, [ref]$v, 4) } catch { }
    })

    Fill-Nodes $script:fdTvA.Nodes '' $script:fdRootA
    Fill-Nodes $script:fdTvB.Nodes '' $script:fdRootB
    Refresh-Trees
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
