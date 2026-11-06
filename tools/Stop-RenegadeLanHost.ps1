#Requires -Version 5.1
<#
.SYNOPSIS
    Stops the Renegade LAN host started by Start-RenegadeLanHost.ps1 and removes
    its generated directory.

.DESCRIPTION
    Removes the Data junction with rmdir (which cannot delete the target's
    contents), deletes the generated host directory, and keeps the run's log as
    last-run-*.log under the state root.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Stop-RenegadeLanHost.ps1
#>
[CmdletBinding()]
param([string]$StatePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Preservation.Common.psm1') -Force

$result = Stop-RenegadeLanHost -StatePath $StatePath
if (-not $result.Stopped) {
    Write-Host ("Nothing to stop: {0} ({1})" -f $result.Reason, $result.StatePath)
    exit 0
}
Write-Host ("Stopped pid {0}; process exited: {1}; host directory removed: {2}" -f $result.ProcessId, $result.ProcessExited, $result.HostRemoved)
Write-Host ("Evidence kept under {0}" -f $result.StatePath)
exit 0
