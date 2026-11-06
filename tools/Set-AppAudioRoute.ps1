#Requires -Version 5.1
<#
.SYNOPSIS
Routes one application's audio to a specific output device through the supported
Windows "App volume and device preferences" page, driven by UI Automation.

.DESCRIPTION
This is the documented per-app API client: the Settings page writes the per-app
routing entry that Windows applies to the process's audio session. It changes only
the named application's output; the system default render device is not touched.

The device is matched by name against the items the page actually offers, and the
match must be unambiguous: if the page lists several items whose names contain the
requested text, the tool refuses rather than guessing.

The Settings window must already be open on ms-settings:apps-volume.

.PARAMETER AppName
Row title of the application, as the page shows it (usually its window title).

.PARAMETER DeviceName
Text that identifies the output device, e.g. a device id such as 100027813.

.PARAMETER AsJson
Emit one JSON object describing what was selected.

.EXAMPLE
powershell -File tools/Set-AppAudioRoute.ps1 -AppName 'Telltale Games' -DeviceName 100027813
#>
param(
    [string]$AppName,
    [string]$DeviceName,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Get-SettingsWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byName = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, 'Settings')
    $window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $byName)
    if (-not $window) {
        throw 'The Settings window is not open. Open ms-settings:apps-volume first.'
    }
    return $window
}

function Find-MatchingItem {
    param([string[]]$Names, [string]$Pattern)
    return @($Names | Where-Object { $_ -like "*$Pattern*" })
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {

if ([string]::IsNullOrWhiteSpace($AppName)) { throw 'AppName is required.' }
if ([string]::IsNullOrWhiteSpace($DeviceName)) { throw 'DeviceName is required.' }

$window = Get-SettingsWindow

$rowCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, $AppName)
$row = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $rowCondition)
if (-not $row) { throw "No mixer row named '$AppName' on the App volume page." }

$combos = $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ComboBox)))
if ($combos.Count -lt 1) { throw "No output selector in the '$AppName' row." }
$output = $combos[0]

$expand = $output.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
$expand.Expand()
Start-Sleep -Milliseconds 900

$itemCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::ListItem)
$items = $output.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)

$names = @($items | ForEach-Object { $_.Current.Name })
$matched = @(Find-MatchingItem -Names $names -Pattern $DeviceName)
if ($matched.Count -eq 0) {
    $expand.Collapse()
    throw "No output device matching '$DeviceName'. Device is not offered by this page."
}
if ($matched.Count -gt 1) {
    $expand.Collapse()
    throw ("Ambiguous device name '$DeviceName': {0} items match ({1}). Refusing to guess." -f
        $matched.Count, ($matched -join '; '))
}

$targetIndex = -1
for ($i = 0; $i -lt $names.Count; $i++) {
    if ($names[$i] -eq $matched[0]) { $targetIndex = $i; break }
}
if ($targetIndex -lt 0) { $expand.Collapse(); throw 'Selected item vanished from the list.' }
$target = $items[$targetIndex]
$select = $target.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
$select.Select()
Start-Sleep -Milliseconds 1200
$expand.Collapse()
Start-Sleep -Milliseconds 400

$result = [ordered]@{
    app         = $AppName
    requested   = $DeviceName
    selected    = $matched[0]
    offered     = $names
    selectedAt  = (Get-Date).ToString('o')
}
if ($AsJson) {
    $result | ConvertTo-Json -Depth 4
} else {
    Write-Host ("routed '{0}' -> {1}" -f $AppName, $matched[0])
}

}
catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    Write-Error ("Set-AppAudioRoute failed at line {0}: {1}" -f $line, $_.Exception.Message)
    exit 1
}
