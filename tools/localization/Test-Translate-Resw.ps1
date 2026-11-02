#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Runs dependency-free regression tests for the resource translation harness.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot 'Translate-Resw.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-localization-test-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$passed = 0

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert ($null -ne $failure) "Expected failure matching '$Pattern'."
    Assert ($failure.Exception.Message -match $Pattern) "Unexpected failure: $($failure.Exception.Message)"
    $script:passed++
}

function Write-Response($Value) {
    ConvertTo-Json -InputObject $Value -Depth 10 | Set-Content -LiteralPath $script:responsePath -Encoding utf8
}

try {
    $source = Join-Path $root 'English.resw'
    $target = Join-Path $root 'missing\de-DE\Resources.resw'
    $work = Join-Path $root 'run'
    $tbx = Join-Path $root 'terms.tbx'
    $fixture = @'
<?xml version="1.0" encoding="utf-8"?>
<root>
  <resheader name="version"><value>2.0</value></resheader>
  <data name="Greeting.Header" xml:space="preserve"><value> Hello {0:#010x}, %s! </value><comment>Greeting</comment></data>
  <data name="Greeting.Description" xml:space="preserve"><value>profile &amp; text</value></data>
  <data name="Path"><value>WSL (C:\ -&gt; /mnt/c)</value><comment>{Locked="WSL","C:\","/mnt/c"}</comment></data>
  <data name="Brace"><value>Binding #{}</value><comment>{Locked="#{}"}</comment></data>
  <data name="Copy"><value>Do not translate</value><comment>{Locked}</comment></data>
  <data name="Url"><value>https://example.com/?a=1&amp;b=2</value></data>
  <data name="Locale"><value>German lock</value><comment>{Locked=de-DE}</comment></data>
  <data name="Partial"><value>BEL and BEL</value><comment>{Locked=BEL}</comment></data>
  <data name="Angles"><value>&lt;unnamed&gt;</value><comment>{Locked="&lt;"}{Locked="&gt;"}</comment></data>
  <data name="Lines"><value>Line one
Line two</value></data>
  <data name="Case"><value>Upper</value></data>
  <data name="case"><value>Lower</value></data>
</root>
'@
    $fixture | Set-Content -LiteralPath $source -Encoding utf8
    @'
<martif><text><body>
<termEntry id="1"><langSet xml:lang="en-US"><descripGrp><descrip type="definition">Settings for a terminal session.</descrip></descripGrp><ntig><termGrp><term>profile</term></termGrp></ntig></langSet><langSet xml:lang="de"><ntig><termGrp><term>Profil</term></termGrp></ntig></langSet></termEntry>
<termEntry id="2"><langSet xml:lang="en-US"><descripGrp><descrip type="definition">A side view.</descrip></descripGrp><ntig><termGrp><term>profile</term></termGrp></ntig></langSet><langSet xml:lang="de"><ntig><termGrp><term>Seitenansicht</term></termGrp></ntig></langSet></termEntry>
<termEntry id="3"><langSet xml:lang="en-US"><ntig><termGrp><term>unrelated</term></termGrp></ntig></langSet><langSet xml:lang="de"><ntig><termGrp><term>irrelevant</term></termGrp></ntig></langSet></termEntry>
</body></text></martif>
'@ | Set-Content -LiteralPath $tbx -Encoding utf8
    & $tool -Operation Prepare -SourcePath $source -TargetPath $target -TargetLanguage de-DE `
        -TerminologyPath $tbx -WorkDirectory $work -BatchSize 1
    $manifest = Get-Content -Raw (Join-Path $work 'manifest.json') | ConvertFrom-Json
    Assert ($manifest.entryCount -eq 12) 'Wrong source entry count.'
    $first = Get-Content -Raw (Join-Path $work 'batch-001.input.json') | ConvertFrom-Json
    Assert ($first.entries.Count -eq 2) 'Related entries were split.'
    $hints = Get-Content -Raw -LiteralPath (Join-Path $work $first.terminologyFile)
    Assert ($hints -ceq 'profile: Profil | Seitenansicht') 'Grouped plain-text hints are incorrect.'
    Assert ($hints -notmatch 'Settings for|side view') 'Definitions leaked into hints.'
    $lookup = Join-Path $PSScriptRoot 'Get-Tbx.ps1'
    $terms = @(& $lookup -Path $tbx -Lang de-DE -Term profile -AsObject)
    Assert (@($terms).Count -eq 2) 'Terminology lookup failed.'
    Assert ($terms[0].definition.Length -gt 0) 'Terminology definitions were lost.'
    Assert ($terms[0].id -ceq '1') 'Concept ID was lost.'
    $plain = (& $tool -Operation Terms -WorkDirectory $work -Query profile) -join "`n"
    Assert ($plain -match '\[1\] profile: Profil' -and $plain -match 'Settings for') 'Readable definition lookup failed.'
    $outside = @(& $lookup -Path $tbx -Lang de-DE -Term unrelated -AsObject)
    Assert ($outside.Count -eq 1) 'Lookup failed for a term absent from the source.'
    $absent = & $lookup -Path $tbx -Lang de-DE -Term 'no such term'
    Assert ($absent -match 'No terminology matches') 'Missing terminology was not reported.'
    $passed += 4
    $passed++
    foreach ($name in $manifest.batches) {
        $input = Get-Content -Raw (Join-Path $work "$name.input.json") | ConvertFrom-Json
        $responsePath = Join-Path $work "$name.output.json"
        $response = @($input.entries | ForEach-Object { @{ id = $_.id; value = $_.source } })
        if ($name -eq 'batch-001') {
            $response[0].value = ' Hallo {0:#010x}, %s! '
            $response[1].value = 'Profil & Text'
        }
        Write-Response $response
    }
    & $tool -Operation Validate -WorkDirectory $work
    & $tool -Operation Complete -WorkDirectory $work
    [xml]$result = Get-Content -Raw -LiteralPath $target
    Assert ($result.root.data.Count -eq 12) 'Wrong assembled entry count.'
    Assert ($result.root.data[1].value -ceq 'Profil & Text') 'XML escaping changed text.'
    Assert ($result.root.data[0].comment -ceq 'Greeting') 'Comment changed.'
    Assert ($result.root.data[0].GetAttribute('space', 'http://www.w3.org/XML/1998/namespace') -ceq 'preserve') 'Attribute lost.'
    Assert ($result.root.data[2].value -ceq 'WSL (C:\ -> /mnt/c)') 'Path changed.'
    $passed++
    Expect-Failure { & $tool -Operation Complete -WorkDirectory $work } 'Target already exists'
    & $tool -Operation Complete -WorkDirectory $work -Force
    $passed++

    $responsePath = Join-Path $work 'batch-001.output.json'
    $good = Get-Content -Raw -LiteralPath $responsePath
    $items = $good | ConvertFrom-Json -AsHashtable -NoEnumerate
    Write-Response @($items[0])
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Missing IDs'
    Write-Response @($items[0], $items[0], $items[1])
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Duplicate ID'
    $items[0].id = 'greeting.Header'
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Unexpected ID'
    $items = $good | ConvertFrom-Json -AsHashtable -NoEnumerate
    $items[0].value = ' Hallo {0:x}, %s! '
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Format tokens changed'
    $items[0].value = ' Hallo {0:#010x}, %s! { '
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Format tokens changed'
    $items[0].value = 'Hallo {0:#010x}, %s!'
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Boundary whitespace'
    $items[0].value = ''
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'Empty translation'
    $items[0].value = $null
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'string id/value'
    $items = $good | ConvertFrom-Json -AsHashtable -NoEnumerate
    $items[0].extra = 'unexpected'
    Write-Response $items
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'string id/value'
    Write-Response @{ id = 'Greeting.Header'; value = 'not an array' }
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'JSON array'
    '{invalid json' | Set-Content -LiteralPath $responsePath
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch batch-001 } 'JSON'
    $good | Set-Content -LiteralPath $responsePath

    foreach ($case in @(
        @{ Batch = 'batch-002'; Value = 'WSL (D:\ -> /mnt/c)'; Error = 'Locked term' },
        @{ Batch = 'batch-003'; Value = 'Tastenkombination {}'; Error = 'Locked term' },
        @{ Batch = 'batch-004'; Value = 'Changed'; Error = 'Whole-value lock' },
        @{ Batch = 'batch-005'; Value = 'https://other.example/'; Error = 'Whole-value lock' },
        @{ Batch = 'batch-006'; Value = 'Changed'; Error = 'Whole-value lock' },
        @{ Batch = 'batch-007'; Value = 'BEL'; Error = 'Locked term' },
        @{ Batch = 'batch-009'; Value = 'Eine Zeile'; Error = 'Line break count' }
    )) {
        $responsePath = Join-Path $work "$($case.Batch).output.json"
        $original = Get-Content -Raw -LiteralPath $responsePath
        $items = $original | ConvertFrom-Json -AsHashtable -NoEnumerate
        $items[0].value = $case.Value
        Write-Response $items
        Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch $case.Batch } $case.Error
        $before = (Get-FileHash -LiteralPath $target).Hash
        Expect-Failure { & $tool -Operation Complete -WorkDirectory $work -Force } $case.Error
        Assert ((Get-FileHash -LiteralPath $target).Hash -ceq $before) 'Failed validation modified target.'
        $original | Set-Content -LiteralPath $responsePath
    }
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work -Batch '..\arbitrary' } 'Unknown batch'
    $inputPath = Join-Path $work 'batch-001.input.json'
    $inputOriginal = Get-Content -Raw -LiteralPath $inputPath
    Add-Content -LiteralPath $inputPath ' '
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $work } 'Batch input changed'
    [IO.File]::WriteAllText($inputPath, $inputOriginal, [Text.UTF8Encoding]::new($false))
    Add-Content -LiteralPath $source ' '
    Expect-Failure { & $tool -Operation Complete -WorkDirectory $work -Force } 'English source changed'
    Expect-Failure {
        & $tool -Operation Prepare -SourcePath $source -TargetPath $target -TargetLanguage de-DE -WorkDirectory $work
    } 'must be empty'
    Expect-Failure {
        & $tool -Operation Prepare -SourcePath $source -TargetPath $source -TargetLanguage de-DE `
            -WorkDirectory (Join-Path $root 'same-source')
    } 'must differ'
    $duplicateSource = Join-Path $root 'duplicates.resw'
    '<root><data name="same"><value>A</value></data><data name="same"><value>B</value></data></root>' |
        Set-Content -LiteralPath $duplicateSource
    Expect-Failure {
        & $tool -Operation Prepare -SourcePath $duplicateSource -TargetPath $target -TargetLanguage de-DE `
            -WorkDirectory (Join-Path $root 'duplicates')
    } 'duplicate resource name'
    $emptySource = Join-Path $root 'empty.resw'
    '<root />' | Set-Content -LiteralPath $emptySource
    Expect-Failure {
        & $tool -Operation Prepare -SourcePath $emptySource -TargetPath $target -TargetLanguage de-DE `
            -WorkDirectory (Join-Path $root 'empty')
    } 'no resource entries'
    $smallWork = Join-Path $root 'small-batches'
    & $tool -Operation Prepare -SourcePath $source -TargetPath $target -TargetLanguage de-DE `
        -WorkDirectory $smallWork -MaxBatchCharacters 100 -BatchSize 1000
    $smallManifest = Get-Content -Raw (Join-Path $smallWork 'manifest.json') | ConvertFrom-Json
    Assert ($smallManifest.batches.Count -eq 11) 'Character budget did not split batches.'
    $smallFirst = Get-Content -Raw (Join-Path $smallWork 'batch-001.input.json') | ConvertFrom-Json
    Assert ($smallFirst.entries.Count -eq 2) 'Character budget split an indivisible resource family.'
    $passed++
    $termFile = Join-Path $smallWork 'batch-001.terms.txt'
    Add-Content -LiteralPath $termFile 'tampered'
    Expect-Failure { & $tool -Operation Validate -WorkDirectory $smallWork -Batch batch-001 } 'Batch terminology changed'

    $manySource = Join-Path $root 'many.resw'
    $manyTbx = Join-Path $root 'many.tbx'
    $names = @(0..39 | ForEach-Object { "term$_" })
    "<root><data name=`"Many`"><value>$($names -join ' ')</value></data></root>" |
        Set-Content -LiteralPath $manySource
    $concepts = foreach ($name in $names) {
        "<termEntry id=`"$name`"><langSet xml:lang=`"en-US`"><ntig><termGrp><term>$name</term></termGrp></ntig></langSet><langSet xml:lang=`"de`"><ntig><termGrp><term>German-$name</term></termGrp></ntig></langSet></termEntry>"
    }
    "<martif><text><body>$($concepts -join '')</body></text></martif>" | Set-Content -LiteralPath $manyTbx
    $manyWork = Join-Path $root 'many'
    & $tool -Operation Prepare -SourcePath $manySource -TargetPath $target -TargetLanguage de-DE `
        -TerminologyPath $manyTbx -WorkDirectory $manyWork
    $manyHints = @(Get-Content -LiteralPath (Join-Path $manyWork 'batch-001.terms.txt'))
    Assert ($manyHints.Count -eq 40) 'Terminology was truncated.'
    Assert ($manyHints -ccontains 'term0: German-term0') 'Short matching term was dropped.'
    $passed++
    Write-Output "Passed $passed translation harness checks."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
