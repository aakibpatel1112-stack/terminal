#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Plans source-key changes and runs the same incremental translation harness locally or in CI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Prepare', 'Translate', 'Complete')][string]$Operation,
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$Language,
    [string]$TerminologyArchive,
    [string]$ResponsesDirectory,
    [string]$Model
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
$repo = [IO.Path]::GetFullPath((git rev-parse --show-toplevel).Trim())
if ((Get-Location).Path -ne $repo) { throw 'Run this script from the repository root.' }
$baselineCommit = (git rev-parse --verify "${Baseline}^{commit}").Trim()
git merge-base --is-ancestor $baselineCommit HEAD
if ($LASTEXITCODE -ne 0) { throw 'Baseline must be an ancestor of HEAD.' }

function Read-Xml([string]$Text) {
    $document = [xml]::new()
    $document.XmlResolver = $null
    $document.LoadXml($Text)
    if ($document.DocumentElement.Name -cne 'root') { throw 'Expected a resw root.' }
    return ,$document
}

function Get-Entries($Document) {
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($node in $Document.SelectNodes('/root/data')) {
        $map.Add($node.GetAttribute('name'), $node)
    }
    return ,$map
}

function Get-Signature($Node) {
    $comment = $Node.SelectSingleNode('comment')
    $value = $Node.SelectSingleNode('value').InnerText.Replace("`r`n", "`n").Replace("`r", "`n")
    $commentText = $(if ($null -ne $comment) { $comment.InnerText.Replace("`r`n", "`n").Replace("`r", "`n") } else { '' })
    return ConvertTo-Json -Compress -InputObject @(
        $value, $commentText
    )
}

function New-Plan {
    $oldFiles = @(git ls-tree -r --name-only $baselineCommit -- 'src')
    $sources = @(@(git ls-files -- 'src') + $oldFiles |
        Where-Object { $_ -match '/en-US/[^/]+\.resw$' } | Sort-Object -Unique)
    $jobs = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($relative in $sources) {
        $index++
        $path = Join-Path $repo ($relative.Replace('/', '\'))
        $deletedFile = -not (Test-Path -LiteralPath $path)
        $current = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if (-not $deletedFile) { $current = Get-Entries (Read-Xml ([IO.File]::ReadAllText($path))) }
        $previous = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if ($oldFiles -ccontains $relative) {
            $previous = Get-Entries (Read-Xml ((git show "${baselineCommit}:$relative") -join "`n"))
        }
        $changed = @($current.Keys | Where-Object {
            -not $previous.ContainsKey($_) -or (Get-Signature $current[$_]) -cne (Get-Signature $previous[$_])
        })
        $resourceRoot = Split-Path (Split-Path $path)
        $relativeRoot = [IO.Path]::GetRelativePath($repo, $resourceRoot).Replace('\', '/')
        $fileName = Split-Path $path -Leaf
        $pattern = '^' + [regex]::Escape($relativeRoot) + '/([^/]+)/' + [regex]::Escape($fileName) + '$'
        $locales = @(
            if (Test-Path -LiteralPath $resourceRoot) {
                Get-ChildItem -LiteralPath $resourceRoot -Directory | ForEach-Object { $_.Name }
            }
            foreach ($oldPath in $oldFiles) {
                if ($oldPath -match $pattern) { $Matches[1] }
            }
        ) | Sort-Object -Unique
        foreach ($locale in $locales) {
            if ($locale -eq 'en-US' -or $locale -like 'qps-*') { continue }
            [void][Globalization.CultureInfo]::GetCultureInfo($locale)
            $target = Join-Path (Join-Path $resourceRoot $locale) $fileName
            $relativeTarget = [IO.Path]::GetRelativePath($repo, $target)
            $gitTarget = $relativeTarget.Replace('\', '/')
            # Some projects ship one file in 85 locales but another in only 12.
            if (-not (Test-Path -LiteralPath $target) -and $oldFiles -cnotcontains $gitTarget) { continue }
            $existing = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            if (Test-Path -LiteralPath $target) {
                $existing = Get-Entries (Read-Xml ([IO.File]::ReadAllText($target)))
            }
            $selected = @($current.Keys | Where-Object {
                $changed -ccontains $_ -or -not (Test-Path -LiteralPath $target)
            })
            $removed = @($previous.Keys | Where-Object {
                -not $current.ContainsKey($_) -and $existing.ContainsKey($_)
            })
            if ($selected.Count -eq 0 -and $removed.Count -eq 0 -and -not $deletedFile) { continue }
            $jobs.Add([ordered]@{
                id = 'resource-{0:D3}' -f $index
                language = $locale
                source = $path
                target = $target
                relativeTarget = $relativeTarget
                keys = $selected
                removed = $removed
                deleteFile = $deletedFile
            })
        }
    }
    return [ordered]@{
        baseline = $baselineCommit
        sourceCommit = (git rev-parse HEAD).Trim()
        languages = @($jobs | ForEach-Object { $_.language } | Sort-Object -Unique)
        jobs = @($jobs.ToArray())
    }
}

function Find-Terminology([string]$Locale) {
    $culture = [Globalization.CultureInfo]::GetCultureInfo($Locale)
    $accepted = [Collections.Generic.List[string]]::new()
    while ($culture.Name) {
        $accepted.Add($culture.Name)
        $culture = $culture.Parent
    }
    if ($Locale -eq 'zh-CN') { $accepted.Insert(1, 'zh-Hans') }
    if ($Locale -eq 'zh-TW') { $accepted.Insert(1, 'zh-Hant') }
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $TerminologyArchive).Path)
    $chosen = $null
    $best = [int]::MaxValue
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.FullName.EndsWith('.tbx')) { continue }
            $stream = $entry.Open()
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $reader = [Xml.XmlReader]::Create($stream, $settings)
            try {
                while ($reader.ReadToFollowing('langSet')) {
                    $lang = $reader.GetAttribute('lang', 'http://www.w3.org/XML/1998/namespace')
                    if ($lang -eq 'en-US') { continue }
                    $rank = -1
                    for ($i = 0; $i -lt $accepted.Count; $i++) {
                        if ($accepted[$i] -ieq $lang) { $rank = $i; break }
                    }
                    if ($rank -ge 0 -and $rank -lt $best) { $chosen = $entry; $best = $rank }
                    break
                }
            }
            finally { $reader.Dispose(); $stream.Dispose() }
        }
        if ($null -eq $chosen) {
            Write-Warning "No Microsoft TBX collection found for $Locale; terminology hints will be empty."
            return $null
        }
        $destination = Join-Path $WorkDirectory 'terminology.tbx'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($chosen, $destination, $false)
        return $destination
    }
    finally { $zip.Dispose() }
}

if ($Operation -eq 'Plan' -or $Operation -eq 'Prepare') {
    if ((Test-Path -LiteralPath $WorkDirectory) -and @(Get-ChildItem -Force -LiteralPath $WorkDirectory).Count) {
        throw 'Use an empty work directory.'
    }
    $plan = New-Plan
    [void][IO.Directory]::CreateDirectory($WorkDirectory)
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $WorkDirectory 'plan.json') -Encoding utf8
    if ($Operation -eq 'Plan') {
        Write-Output "Planned $($plan.jobs.Count) resource/language updates across $($plan.languages.Count) languages."
        return
    }
    if (-not $Language) { throw '-Language is required for Prepare.' }
    $terminology = $null
    if ($TerminologyArchive) { $terminology = Find-Terminology $Language }
    foreach ($job in $plan.jobs | Where-Object { $_.language -ceq $Language }) {
        if ($job.deleteFile) { continue }
        & "$PSScriptRoot\Translate-Resw.ps1" -Operation Prepare -WorkDirectory (Join-Path $WorkDirectory $job.id) `
            -SourcePath $job.source -TargetPath $job.target -TargetLanguage $Language `
            -TerminologyPath $terminology -Incremental -ResourceIds $job.keys -RemovedIds $job.removed
    }
    return
}

if (-not $Language) { throw '-Language is required.' }
$plan = Get-Content -Raw -LiteralPath (Join-Path $WorkDirectory 'plan.json') | ConvertFrom-Json -AsHashtable
if ($plan.baseline -cne $baselineCommit -or $plan.sourceCommit -cne (git rev-parse HEAD).Trim()) {
    throw 'Plan no longer matches the baseline/source commits.'
}
$instructions = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Translation-Instructions.md'))
foreach ($job in $plan.jobs | Where-Object { $_.language -ceq $Language }) {
    if ($job.deleteFile) {
        if ($Operation -eq 'Complete' -and (Test-Path -LiteralPath $job.target)) { Remove-Item -LiteralPath $job.target }
        continue
    }
    $work = Join-Path $WorkDirectory $job.id
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $work 'manifest.json') | ConvertFrom-Json
    foreach ($batch in $manifest.batches) {
        $output = Join-Path $work "$batch.output.json"
        if ($Operation -eq 'Translate') {
            if (-not (Test-Path -LiteralPath $output)) {
                $prompt = @"
$instructions

Translate into $Language. Repository: $repo
Resource project: $($job.source)
Read input: $(Join-Path $work "$batch.input.json")
Read terminology: $(Join-Path $work "$batch.terms.txt")
Write JSON response only to: $output
Definition lookup: & '$PSScriptRoot\Translate-Resw.ps1' -Operation Terms -WorkDirectory '$work' -Query 'term'
Do not change any other files. Do not run git write commands or publish changes.
"@
                $arguments = @('-p', $prompt, '--no-ask-user', '--no-auto-update', '--add-dir', $WorkDirectory,
                    '--allow-tool', 'read', '--allow-tool', 'write',
                    '--allow-tool', 'shell(pwsh:*)', '--allow-tool', 'shell(rg:*)', '-s')
                if ($Model) { $arguments += @('--model', $Model) }
                & copilot @arguments
                if ($LASTEXITCODE -ne 0) { throw "Copilot failed for $Language/$($job.id)/$batch" }
            }
        }
        elseif ($ResponsesDirectory) {
            $response = Join-Path (Join-Path $ResponsesDirectory $job.id) "$batch.output.json"
            Copy-Item -LiteralPath $response -Destination $output
        }
        & "$PSScriptRoot\Translate-Resw.ps1" -Operation Validate -WorkDirectory $work -Batch $batch
    }
    if ($Operation -eq 'Complete') {
        & "$PSScriptRoot\Translate-Resw.ps1" -Operation Complete -WorkDirectory $work
    }
}
