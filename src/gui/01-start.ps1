if ($NoGui) { return }
# Kern-Funktionen merken (Name und Text): der Sync-Thread bekommt genau diese, nicht die Datei auf der Platte
# (die koennte inzwischen durch ein Update ersetzt sein)
$script:coreFns = @(Get-ChildItem function: | Where-Object { $_.ScriptBlock.File -eq $PSCommandPath } | ForEach-Object { , @($_.Name, $_.Definition) })

# ================================================================ GUI
Load-Tasks

