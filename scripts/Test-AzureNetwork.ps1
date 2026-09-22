#requires -Version 7.2
[CmdletBinding()]
param()
. "$PSScriptRoot\Azure-Common.ps1"
Assert-AzureContext
$network = Get-PrivateNetworkStatus (Get-BootstrapOutputs)
Write-Host 'Private network ARM checks passed. Runtime DNS, MI data access, and KEDA still require in-environment verification.'
$network
