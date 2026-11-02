#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Prepares, validates, and assembles batched resource translations without invoking a model.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Validate', 'Complete', 'Terms')]
    [string]$Operation,
    [Parameter(Mandatory)]
    [string]$WorkDirectory,
    [string]$SourcePath,
    [string]$TargetPath,
    [string]$TargetLanguage,
    [string]$TerminologyPath,
    [switch]$Incremental,
    [string[]]$ResourceIds = @(),
    [string[]]$RemovedIds = @(),
    [ValidateRange(1, 1000)]
    [int]$BatchSize = 60,
    [ValidateRange(100, 1000000)]
    [int]$MaxBatchCharacters = 16000,
    [string]$Batch,
    [string]$Query,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)

function Read-Resource([string]$Path) {
    $document = [xml]::new()
    $document.PreserveWhitespace = $true
    $document.XmlResolver = $null
    $document.Load($Path)
    if ($document.DocumentElement.Name -cne 'root') {
        throw "Expected a resw root element: $Path"
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $document.SelectNodes('/root/data')) {
        if (-not $entry.HasAttribute('name') -or -not $seen.Add($entry.GetAttribute('name'))) {
            throw "Missing or duplicate resource name in $Path"
        }
        if ($entry.SelectNodes('value').Count -ne 1) {
            throw "Expected exactly one value for $($entry.GetAttribute('name'))"
        }
    }
    return ,$document
}

function Write-JsonFile($Value, [string]$Path) {
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-Protection([string]$Value, [string]$Comment, [string]$Language) {
    $locked = [Collections.Generic.List[string]]::new()
    $wholeValue = $Value -match '^https?://\S+$'
    # Quoted locked terms may themselves contain braces or commas.
    foreach ($directive in [regex]::Matches($Comment, '\{Locked(?:=(?<terms>(?:"[^"]*"|[^"}])*))?\}')) {
        $terms = $directive.Groups['terms'].Value
        if ($terms.Length -eq 0) {
            $wholeValue = $true
            continue
        }
        foreach ($part in ($terms -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)')) {
            $term = $part.Trim()
            if ($term.StartsWith('"') -and $term.EndsWith('"')) {
                $term = $term.Substring(1, $term.Length - 2)
            }
            if ($term.Length -eq 0) {
                throw "Empty locked term: $Comment"
            }
            if ($term -ceq $Language) {
                $wholeValue = $true
            }
            if ($Value.Contains($term) -and -not $locked.Contains($term)) {
                $locked.Add($term)
            }
        }
    }
    return @{ locked = @($locked.ToArray()); copy = $wholeValue }
}

function Get-FormatTokens([string]$Value) {
    $pattern = '\{\{|\}\}|\{[^{}]*\}|[{}]|%(?:\d+\$)?[-+#0 '']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[diuoxXfFeEgGaAcspn%]'
    return @([regex]::Matches($Value, $pattern) | ForEach-Object { $_.Value } | Sort-Object -CaseSensitive)
}

function Assert-Translation($Entry, [string]$Value) {
    if ($Entry.copy -and $Value -cne $Entry.source) {
        throw "Whole-value lock changed: $($Entry.id)"
    }
    if ($Entry.source.Length -gt 0 -and [string]::IsNullOrWhiteSpace($Value)) {
        throw "Empty translation: $($Entry.id)"
    }
    if ((ConvertTo-Json -Compress -InputObject @(Get-FormatTokens $Entry.source)) -cne
        (ConvertTo-Json -Compress -InputObject @(Get-FormatTokens $Value))) {
        throw "Format tokens changed: $($Entry.id)"
    }
    foreach ($term in $Entry.locked) {
        $pattern = [regex]::Escape($term)
        if ([regex]::Matches($Entry.source, $pattern).Count -ne [regex]::Matches($Value, $pattern).Count) {
            throw "Locked term '$term' changed: $($Entry.id)"
        }
    }
    foreach ($pattern in @('^\s*', '\s*$')) {
        if ([regex]::Match($Entry.source, $pattern).Value -cne [regex]::Match($Value, $pattern).Value) {
            throw "Boundary whitespace changed: $($Entry.id)"
        }
    }
    if ([regex]::Matches($Entry.source, '\r\n|\r|\n').Count -ne [regex]::Matches($Value, '\r\n|\r|\n').Count) {
        throw "Line break count changed: $($Entry.id)"
    }
    [void][Xml.XmlConvert]::VerifyXmlChars($Value)
}

function Test-TermMatch([string]$Text, [string]$Term) {
    return [regex]::IsMatch($Text, '(?<![\p{L}\p{N}])' + [regex]::Escape($Term) + '(?![\p{L}\p{N}])',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-Terminology([string]$Path, [string]$Language, $Entries) {
    $sourceText = ($Entries | ForEach-Object { $_.source }) -join "`n"
    return @(& "$PSScriptRoot\Get-Tbx.ps1" -Path $Path -Lang $Language -Text $sourceText -AsObject)
}

function Assert-Snapshot($Manifest) {
    if ((Get-FileHash -LiteralPath $Manifest.sourcePath -Algorithm SHA256).Hash -cne $Manifest.sourceHash) {
        throw 'English source changed. Prepare a new run instead of applying stale translations.'
    }
}

function Read-ValidatedBatch($Manifest, [string]$Name) {
    if ($Manifest.batches -cnotcontains $Name) { throw "Unknown batch: $Name" }
    $requestPath = Join-Path $WorkDirectory "$Name.input.json"
    if ((Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash -cne $Manifest.inputHashes[$Name]) {
        throw "Batch input changed: $Name"
    }
    if ((Get-FileHash -LiteralPath (Join-Path $WorkDirectory "$Name.terms.txt") -Algorithm SHA256).Hash -cne
        $Manifest.termHashes[$Name]) {
        throw "Batch terminology changed: $Name"
    }
    $request = Get-Content -Raw -LiteralPath $requestPath | ConvertFrom-Json -AsHashtable
    $response = Get-Content -Raw -LiteralPath (Join-Path $WorkDirectory "$Name.output.json") |
        ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($response -isnot [Collections.IList]) { throw "Expected a JSON array: $Name" }
    $expected = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $request.entries) { $expected.Add($entry.id, $entry) }
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($item in $response) {
        if ($item -isnot [Collections.IDictionary] -or $item.Count -ne 2 -or
            -not $item.Contains('id') -or -not $item.Contains('value') -or
            $item.id -isnot [string] -or $item.value -isnot [string]) {
            throw "Expected objects containing only string id/value fields: $Name"
        }
        if (-not $expected.ContainsKey($item.id)) { throw "Unexpected ID '$($item.id)': $Name" }
        if ($values.ContainsKey($item.id)) { throw "Duplicate ID '$($item.id)': $Name" }
        Assert-Translation $expected[$item.id] $item.value
        $values.Add($item.id, $item.value)
    }
    $missing = @($expected.Keys | Where-Object { -not $values.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "Missing IDs in ${Name}: $($missing -join ', ')" }
    return ,$values
}

if ($Operation -eq 'Prepare') {
    foreach ($required in @('SourcePath', 'TargetPath', 'TargetLanguage')) {
        if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required for Prepare." }
    }
    [void][Globalization.CultureInfo]::GetCultureInfo($TargetLanguage)
    $SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
    $TargetPath = [IO.Path]::GetFullPath($TargetPath)
    if ($SourcePath -eq $TargetPath) { throw 'Source and target paths must differ.' }
    if ((Test-Path -LiteralPath $WorkDirectory) -and
        @(Get-ChildItem -Force -LiteralPath $WorkDirectory).Count -gt 0) {
        throw 'WorkDirectory must be empty. Use a separate directory for each run.'
    }
    $document = Read-Resource $SourcePath
    $targetHash = $null
    if ($Incremental -and (Test-Path -LiteralPath $TargetPath)) {
        $targetHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
    }
    $entries = @(
        foreach ($node in $document.SelectNodes('/root/data')) {
            if ($Incremental -and $ResourceIds -cnotcontains $node.GetAttribute('name')) { continue }
            $comment = $node.SelectSingleNode('comment')
            $text = $(if ($null -ne $comment) { $comment.InnerText } else { '' })
            $value = $node.SelectSingleNode('value').InnerText
            $protection = Get-Protection $value $text $TargetLanguage
            [ordered]@{
                id = $node.GetAttribute('name')
                source = $value
                comment = $text
                locked = $protection.locked
                copy = $protection.copy
            }
        }
    )
    if ($entries.Count -eq 0 -and -not $Incremental) { throw 'Source contains no resource entries.' }
    if ($Incremental) {
        foreach ($id in $ResourceIds) {
            if (@($entries | Where-Object { $_.id -ceq $id }).Count -ne 1) {
                throw "Selected resource does not exist: $id"
            }
        }
    }
    $terminology = @()
    if ($TerminologyPath) {
        $TerminologyPath = (Resolve-Path -LiteralPath $TerminologyPath).Path
        $terminology = @(Get-Terminology $TerminologyPath $TargetLanguage $entries)
    }
    [void][IO.Directory]::CreateDirectory($WorkDirectory)
    Write-JsonFile $terminology (Join-Path $WorkDirectory 'terminology.json')
    $groups = [Collections.Generic.List[object]]::new()
    $current = [Collections.Generic.List[object]]::new()
    $lastFamily = ''
    foreach ($entry in $entries) {
        $family = ($entry.id -split '\.', 2)[0]
        if ($current.Count -gt 0 -and $family -cne $lastFamily) {
            $groups.Add($current.ToArray())
            $current.Clear()
        }
        $current.Add($entry)
        $lastFamily = $family
    }
    if ($current.Count -gt 0) { $groups.Add($current.ToArray()) }
    $batches = [Collections.Generic.List[object]]::new()
    $current.Clear()
    $characters = 0
    foreach ($group in $groups) {
        $size = (ConvertTo-Json -InputObject $group -Depth 10 -Compress).Length
        if ($current.Count -gt 0 -and
            ($current.Count + $group.Count -gt $BatchSize -or $characters + $size -gt $MaxBatchCharacters)) {
            $batches.Add($current.ToArray())
            $current.Clear()
            $characters = 0
        }
        foreach ($entry in $group) { $current.Add($entry) }
        $characters += $size
    }
    if ($current.Count -gt 0) { $batches.Add($current.ToArray()) }
    $names = @()
    $hashes = @{}
    $termHashes = @{}
    for ($i = 0; $i -lt $batches.Count; $i++) {
        $name = 'batch-{0:D3}' -f ($i + 1)
        $names += $name
        $batchText = ($batches[$i] | ForEach-Object { $_.source }) -join "`n"
        $matches = @($terminology | Where-Object { Test-TermMatch $batchText $_.source } |
            Select-Object source, target | Sort-Object source, target -Unique)
        $lines = @($matches | Group-Object source | ForEach-Object {
            $_.Name + ': ' + ($_.Group.target -join ' | ')
        })
        $termPath = Join-Path $WorkDirectory "$name.terms.txt"
        [IO.File]::WriteAllText($termPath, ($lines -join "`n"), [Text.UTF8Encoding]::new($false))
        $termHashes[$name] = (Get-FileHash -LiteralPath $termPath -Algorithm SHA256).Hash
        $inputPath = Join-Path $WorkDirectory "$name.input.json"
        Write-JsonFile ([ordered]@{
            targetLanguage = $TargetLanguage
            entries = @($batches[$i])
            terminologyFile = "$name.terms.txt"
        }) $inputPath
        $hashes[$name] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
    }
    Write-JsonFile ([ordered]@{
        sourcePath = $SourcePath
        sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        targetPath = $TargetPath
        targetLanguage = $TargetLanguage
        incremental = [bool]$Incremental
        targetHash = $targetHash
        removedIds = $RemovedIds
        entryCount = $entries.Count
        terminologyPath = $TerminologyPath
        terminologyHash = $(if ($TerminologyPath) { (Get-FileHash -LiteralPath $TerminologyPath -Algorithm SHA256).Hash } else { $null })
        batches = $names
        inputHashes = $hashes
        termHashes = $termHashes
    }) (Join-Path $WorkDirectory 'manifest.json')
    Write-Output "Prepared $($entries.Count) entries in $($names.Count) batches; $($terminology.Count) terminology matches."
    return
}

if ($Operation -eq 'Terms') {
    if (-not $Query) { throw '-Query is required for Terms.' }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $WorkDirectory 'manifest.json') | ConvertFrom-Json -AsHashtable
    if (-not $manifest.terminologyPath) { throw 'No terminology collection configured for this run.' }
    if ((Get-FileHash -LiteralPath $manifest.terminologyPath -Algorithm SHA256).Hash -cne $manifest.terminologyHash) {
        throw 'Terminology collection changed since Prepare.'
    }
    & "$PSScriptRoot\Get-Tbx.ps1" -Path $manifest.terminologyPath -Lang $manifest.targetLanguage -Term $Query
    return
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $WorkDirectory 'manifest.json') | ConvertFrom-Json -AsHashtable
Assert-Snapshot $manifest
if ($Operation -eq 'Validate') {
    $selected = $(if ($Batch) { @($Batch) } else { @($manifest.batches) })
    foreach ($name in $selected) {
        $values = Read-ValidatedBatch $manifest $name
        Write-Output "Validated ${name}: $($values.Count) entries."
    }
    return
}

$all = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
foreach ($name in $manifest.batches) {
    $values = Read-ValidatedBatch $manifest $name
    foreach ($pair in $values.GetEnumerator()) { $all.Add($pair.Key, $pair.Value) }
}
if ($all.Count -ne $manifest.entryCount) { throw 'Total entry count differs from source.' }
$incrementalRun = $manifest.ContainsKey('incremental') -and $manifest.incremental
if ((Test-Path -LiteralPath $manifest.targetPath) -and -not $Force -and -not $incrementalRun) {
    throw 'Target already exists. Use -Force to explicitly replace it.'
}
$document = Read-Resource $manifest.sourcePath
if ($incrementalRun) {
    $exists = Test-Path -LiteralPath $manifest.targetPath
    if ($exists -ne [bool]$manifest.targetHash -or
        ($exists -and (Get-FileHash -LiteralPath $manifest.targetPath -Algorithm SHA256).Hash -cne $manifest.targetHash)) {
        throw 'Target changed since Prepare.'
    }
    $sourceDocument = $document
    if ($exists) { $document = Read-Resource $manifest.targetPath }
    $sourceNodes = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($node in $sourceDocument.SelectNodes('/root/data')) { $sourceNodes.Add($node.GetAttribute('name'), $node) }
    $targetNodes = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($node in @($document.SelectNodes('/root/data'))) {
        $id = $node.GetAttribute('name')
        if ($manifest.removedIds -ccontains $id) {
            $whitespace = $node.PreviousSibling
            [void]$node.ParentNode.RemoveChild($node)
            if ($null -ne $whitespace -and $whitespace -is [Xml.XmlWhitespace]) {
                [void]$whitespace.ParentNode.RemoveChild($whitespace)
            }
        }
        else { $targetNodes.Add($id, $node) }
    }
    foreach ($pair in $sourceNodes.GetEnumerator()) {
        $id = $pair.Key
        if ($all.ContainsKey($id)) {
            $replacement = $document.ImportNode($pair.Value, $true)
            $replacement.SelectSingleNode('value').InnerText = $all[$id]
            if ($targetNodes.ContainsKey($id)) {
                [void]$document.DocumentElement.ReplaceChild($replacement, $targetNodes[$id])
            }
            else {
                [void]$document.DocumentElement.AppendChild($document.CreateWhitespace("`r`n  "))
                [void]$document.DocumentElement.AppendChild($replacement)
                [void]$document.DocumentElement.AppendChild($document.CreateWhitespace("`r`n"))
            }
        }
        elseif (-not $exists) {
            throw "Missing translation for unchanged resource: $id"
        }
    }
}
else {
    foreach ($node in $document.SelectNodes('/root/data')) {
        $node.SelectSingleNode('value').InnerText = $all[$node.GetAttribute('name')]
    }
}
$parent = Split-Path -Parent $manifest.targetPath
[void][IO.Directory]::CreateDirectory($parent)
$temporary = Join-Path $parent ([IO.Path]::GetRandomFileName())
try {
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Encoding = [Text.UTF8Encoding]::new($false)
    $settings.NewLineHandling = [Xml.NewLineHandling]::None
    $writer = [Xml.XmlWriter]::Create($temporary, $settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
    $check = Read-Resource $temporary
    foreach ($node in $check.SelectNodes('/root/data')) {
        $id = $node.GetAttribute('name')
        if ($all.ContainsKey($id) -and $node.SelectSingleNode('value').InnerText -cne $all[$id]) {
            throw "XML round-trip changed value: $($node.GetAttribute('name'))"
        }
    }
    [IO.File]::Move($temporary, $manifest.targetPath, ([bool]$Force -or $incrementalRun))
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
Write-Output "Created $($manifest.targetPath) with $($all.Count) validated entries."
