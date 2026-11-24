# ---- Listen: Sortieren per Klick auf die Spaltenkoepfe, Markieren und Kopieren (Strg+C, Rechtsklick)
if (-not ('DirToyLvSorter' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections;
using System.Windows.Forms;
public class DirToyLvSorter : IComparer {
    public int Col; public bool Asc;
    public int Compare(object a, object b) {
        string x = ((ListViewItem)a).SubItems[Col].Text, y = ((ListViewItem)b).SubItems[Col].Text;
        int r = string.Compare(x, y, StringComparison.CurrentCultureIgnoreCase);
        return Asc ? r : -r;
    }
}
'@
}
function Copy-ListRows($lv, [bool]$all) {
    $items = if ($all) { @($lv.Items) } else { @($lv.SelectedItems) }
    if ($items.Count -eq 0) { return }
    $sb = New-Object System.Text.StringBuilder
    foreach ($it in $items) { [void]$sb.AppendLine((@($it.SubItems | ForEach-Object { $_.Text }) -join "`t")) }
    try { [System.Windows.Forms.Clipboard]::SetText($sb.ToString()) } catch { }
}
function Select-AllRows($lv) { $lv.BeginUpdate(); try { foreach ($i in $lv.Items) { $i.Selected = $true } } finally { $lv.EndUpdate() } }
function Set-ListBehavior($lv, [bool]$sortable, [int]$rowH) {
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.BorderStyle = 'None'; $lv.OwnerDraw = $true; $lv.Font = $fSmall
    $lv.BackColor = $th.Surface; $lv.ForeColor = $th.Text
    $lv.HeaderStyle = $(if ($sortable) { 'Clickable' } else { 'Nonclickable' })
    $il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = New-Object System.Drawing.Size(1, $rowH); $lv.SmallImageList = $il
    $lv.Tag = @{ Col = -1; Asc = $true }
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $br = New-Object System.Drawing.SolidBrush($script:th.Surface); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($script:th.Border)
        $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1); $pen.Dispose()
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
        $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Left
        $txt = $e.Header.Text.ToUpper()
        $st = $s.Tag
        if ($st -and $st.Col -eq $e.ColumnIndex) { $txt += $(if ($st.Asc) { ' ' + [char]0x25B2 } else { ' ' + [char]0x25BC }) }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $s.Font, $r, $script:th.Muted, $fl)
    })
    $lv.Add_DrawItem({ param($s, $e) })
    $lv.Add_DrawSubItem({
        param($s, $e)
        $bg = if ($e.Item.Selected) { $script:th.SelBg } else { $script:th.Surface }
        $br = New-Object System.Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
        $col = if ($e.ColumnIndex -eq ($s.Columns.Count - 1)) { $e.Item.ForeColor } else { $script:th.Text }
        $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, $r, $col, $fl)
    })
    if ($sortable) {
        $lv.Add_ColumnClick({
            param($s, $e)
            if ($script:busy) { return }
            $st = $s.Tag
            if ($st.Col -eq $e.Column) { $st.Asc = -not $st.Asc } else { $st.Col = $e.Column; $st.Asc = $true }
            $so = New-Object DirToyLvSorter; $so.Col = $e.Column; $so.Asc = $st.Asc
            $s.ListViewItemSorter = $so
            $s.Invalidate()
        })
    }
    $lv.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq 'C') { Copy-ListRows $s $false; $e.SuppressKeyPress = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'A') { Select-AllRows $s; $e.SuppressKeyPress = $true }
    })
    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $m1 = $cm.Items.Add('Markierte Zeilen kopieren (Strg+C)'); $m2 = $cm.Items.Add('Alle Zeilen kopieren'); $m3 = $cm.Items.Add('Alles markieren (Strg+A)')
    $m1.Add_Click({ Copy-ListRows $this.Owner.SourceControl $false })
    $m2.Add_Click({ Copy-ListRows $this.Owner.SourceControl $true })
    $m3.Add_Click({ Select-AllRows $this.Owner.SourceControl })
    $lv.ContextMenuStrip = $cm
}

