Import-Module .\src\DeploymentDrift.Common.psd1 -Force
Write-Host 'Module loaded'
$inv = Get-FileInventory -RootPath 'C:\Architect\2251_MU' -IncludePatterns @('Portal\\Web.config','web.config') -ErrorAction SilentlyContinue
Write-Host ("Count: {0}" -f ($inv.Count))
foreach ($i in $inv) { Write-Host $i.relativePath }
$inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$env:TEMP\bd_inv.json" -Force
Write-Host "Wrote $env:TEMP\bd_inv.json"
