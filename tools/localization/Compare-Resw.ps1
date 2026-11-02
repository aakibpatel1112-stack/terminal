#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Creates an HTML comparison in English resource order.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$TranslationPath,
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$PreviousRunPath,
    [switch]$DifferencesOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-Values([string]$Path) {
    $document = [xml]::new()
    $document.XmlResolver = $null
    $document.Load((Resolve-Path -LiteralPath $Path).Path)
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($node in $document.SelectNodes('/root/data')) {
        $values.Add($node.GetAttribute('name'), $node.SelectSingleNode('value').InnerText)
    }
    return ,$values
}
$source = Read-Values $SourcePath
$translation = Read-Values $TranslationPath
$baseline = Read-Values $BaselinePath
$previous = $(if ($PreviousRunPath) { Read-Values $PreviousRunPath } else { $null })
if ($source.Count -ne $translation.Count) { throw 'Source and translation entry counts differ.' }
$rows = @(
    foreach ($pair in $source.GetEnumerator()) {
        if (-not $translation.ContainsKey($pair.Key)) { throw "Missing translation: $($pair.Key)" }
        $row = [ordered]@{
            ID = $pair.Key
            English = $pair.Value
            'Generated German' = $translation[$pair.Key]
            'Original GCS German' = $(if ($baseline.ContainsKey($pair.Key)) { $baseline[$pair.Key] } else { '[missing]' })
        }
        if ($null -ne $previous) {
            $row['First experiment'] = $(if ($previous.ContainsKey($pair.Key)) { $previous[$pair.Key] } else { '[missing]' })
        }
        [pscustomobject]$row
    }
)
$changed = @($rows | Where-Object { $_.'Generated German' -cne $_.'Original GCS German' }).Count
$missing = @($rows | Where-Object { $_.'Original GCS German' -ceq '[missing]' }).Count
$fromPrevious = $(if ($null -ne $previous) {
    @($rows | Where-Object { $_.'Generated German' -cne $_.'First experiment' }).Count
} else { $null })
$head = @'
<meta charset="utf-8">
<style>
body{font:14px system-ui;margin:2em}table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:.6em;text-align:left;vertical-align:top;white-space:pre-wrap}
th{position:sticky;top:0;background:#eee}td:first-child{font:12px monospace;overflow-wrap:anywhere}
</style>
'@
$intro = "<h1>English to German translation experiment</h1><p>$($rows.Count) entries; $changed differ from original GCS; $missing previously missing."
if ($null -ne $fromPrevious) { $intro += " $fromPrevious differ from the first experiment." }
$intro += ' Linguistic quality requires human review.</p>'
$displayRows = $rows
if ($DifferencesOnly) {
    $displayRows = @($rows | Where-Object { $_.'Generated German' -cne $_.'Original GCS German' })
    $intro += "<p>Showing only the $($displayRows.Count) entries that differ from original GCS.</p>"
}
$displayRows | ConvertTo-Html -Title 'Terminal German translation comparison' -Head $head -PreContent $intro |
    Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output "Created $OutputPath ($($rows.Count) entries; $changed differ from GCS; $fromPrevious differ from first experiment)."
