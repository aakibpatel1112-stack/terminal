#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Looks up Microsoft TBX concepts, returning readable definitions by default.
#>
[CmdletBinding(DefaultParameterSetName = 'Term')]
param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [string]$Lang,
    [Parameter(Mandatory, ParameterSetName = 'Term')]
    [ValidateNotNullOrEmpty()]
    [string]$Term,
    [Parameter(Mandatory, ParameterSetName = 'Text')]
    [string]$Text,
    [switch]$AsObject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::GetCultureInfo($Lang)
$languages = @($culture.Name, $culture.Parent.Name)
$results = [Collections.Generic.List[object]]::new()
$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$reader = [Xml.XmlReader]::Create((Resolve-Path -LiteralPath $Path).Path, $settings)
try {
    while ($reader.ReadToFollowing('termEntry')) {
        $subtree = $reader.ReadSubtree()
        $node = [xml]::new()
        $node.XmlResolver = $null
        try { $node.Load($subtree) } finally { $subtree.Dispose() }
        $english = $null
        foreach ($langSet in $node.SelectNodes('//langSet')) {
            if ($langSet.GetAttribute('lang', 'http://www.w3.org/XML/1998/namespace') -ceq 'en-US') {
                $english = $langSet
                break
            }
        }
        if ($null -eq $english) { continue }
        $matched = @(
            foreach ($source in $english.SelectNodes('.//term')) {
                $value = $source.InnerText
                if ($PSCmdlet.ParameterSetName -eq 'Term') {
                    if ($value -ieq $Term) { $value }
                }
                elseif ($value.Length -gt 2 -and [regex]::IsMatch($Text,
                    '(?<![\p{L}\p{N}])' + [regex]::Escape($value) + '(?![\p{L}\p{N}])',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                    $value
                }
            }
        )
        if ($matched.Count -eq 0) { continue }
        $definition = $english.SelectSingleNode('.//descrip[@type="definition"]')
        foreach ($langSet in $node.SelectNodes('//langSet')) {
            if ($languages -notcontains $langSet.GetAttribute('lang', 'http://www.w3.org/XML/1998/namespace')) { continue }
            foreach ($target in $langSet.SelectNodes('.//term')) {
                foreach ($source in $matched) {
                    $results.Add([pscustomobject]@{
                        id = $node.DocumentElement.GetAttribute('id')
                        source = $source
                        target = $target.InnerText
                        definition = $(if ($null -ne $definition) { $definition.InnerText } else { '' })
                    })
                }
            }
        }
    }
}
finally { $reader.Dispose() }
$records = @($results.ToArray() | Sort-Object source, target, definition, id -Unique)
if ($AsObject) {
    $records
}
elseif ($records.Count -eq 0) {
    Write-Output "No terminology matches for '$Term' in $Lang."
}
else {
    foreach ($record in $records) {
        Write-Output "[$($record.id)] $($record.source): $($record.target)"
        Write-Output "  $($record.definition)"
    }
}
