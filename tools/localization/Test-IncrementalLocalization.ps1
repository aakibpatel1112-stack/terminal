#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Exercises source-only planning and artifact application in an isolated temporary repository.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$runner = Join-Path $PSScriptRoot 'Invoke-Localization.ps1'
$translator = Join-Path $PSScriptRoot 'Translate-Resw.ps1'
$publisher = Join-Path $PSScriptRoot 'Publish-Localization.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-incremental-test-' + [guid]::NewGuid())
$originalLocation = Get-Location
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert ($null -ne $failure -and $failure.Exception.Message -match $Pattern) "Expected failure '$Pattern', got '$failure'."
}
function Write-Fixture([string]$Path, [string]$Value) {
    [void][IO.Directory]::CreateDirectory((Split-Path $Path))
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}
function Write-Responses([string]$Work, [string]$OutputRoot) {
    foreach ($directory in Get-ChildItem -LiteralPath $Work -Directory -Filter 'resource-*') {
        foreach ($inputFile in Get-ChildItem -LiteralPath $directory.FullName -Filter '*.input.json') {
            $batch = Get-Content -Raw -LiteralPath $inputFile.FullName | ConvertFrom-Json
            $values = @($batch.entries | ForEach-Object { @{ id = $_.id; value = 'Translated: ' + $_.source } })
            $destination = Join-Path (Join-Path $OutputRoot $directory.Name) ($inputFile.Name.Replace('.input.', '.output.'))
            Write-Fixture $destination (ConvertTo-Json -InputObject $values -Depth 10)
        }
    }
}
try {
    [void][IO.Directory]::CreateDirectory($root)
    Set-Location $root
    git init --quiet
    git config user.name 'Localization test'
    git config user.email 'localization-test@example.invalid'
    git config core.autocrlf false
    $source = Join-Path $root 'src\Test\Resources\en-US\Resources.resw'
    $target = Join-Path $root 'src\Test\Resources\de-DE\Resources.resw'
    $french = Join-Path $root 'src\Test\Resources\fr-FR\Resources.resw'
    $pseudo = Join-Path $root 'src\Test\Resources\qps-ploc\Resources.resw'
    $old = '<root><data name="Stable"><value>Direct3D 11</value></data><data name="Changed"><value>Old</value></data><data name="Comment"><value>Same</value><comment>Old comment</comment></data><data name="Removed"><value>Remove me</value></data></root>'
    $stableComment = "<comment>Line one`r`nLine two</comment>"
    $old = $old.Replace('Direct3D 11</value>', "Direct3D 11</value>$stableComment")
    Write-Fixture $source $old
    $localized = "<root><data name=`"Stable`"><value>Direct3D$([char]0xa0)11</value><comment>Keep this comment</comment></data><data name=`"Changed`"><value>Alt</value></data><data name=`"Comment`"><value>Gleich</value></data><data name=`"Removed`"><value>Entfernen</value></data><data name=`"Legacy`"><value>Unrelated old key</value></data></root>"
    Write-Fixture $target $localized
    Write-Fixture $french $localized
    Write-Fixture $pseudo $old
    # A second file is deliberately missing in German at the source tip.
    $missingSource = Join-Path $root 'src\Test\Resources\en-US\Missing.resw'
    $missingTarget = Join-Path $root 'src\Test\Resources\de-DE\Missing.resw'
    Write-Fixture $missingSource '<root><data name="Missing"><value>Hello</value></data></root>'
    Write-Fixture $missingTarget '<root><data name="Missing"><value>Hallo</value></data></root>'
    git add -- src
    git commit --quiet -m baseline
    $baseline = (git rev-parse HEAD).Trim()
    $current = '<root><data name="Stable"><value>Direct3D 11</value></data><data name="Changed"><value>New</value></data><data name="Comment"><value>Same</value><comment>Updated comment</comment></data><data name="Added"><value>Added</value></data></root>'
    $current = $current.Replace('Direct3D 11</value>', "Direct3D 11</value>$stableComment")
    Write-Fixture $source $current
    Remove-Item -LiteralPath $missingTarget
    # Target-only changes must not cause unrelated source keys to be selected.
    Write-Fixture $french ($localized.Replace('Alt', 'Target-only edit'))
    git add -- src
    git commit --quiet -m current

    $planWork = Join-Path $root 'plan'
    & $runner -Operation Plan -Baseline $baseline -WorkDirectory $planWork
    $plan = Get-Content -Raw (Join-Path $planWork 'plan.json') | ConvertFrom-Json
    Assert ($plan.jobs.Count -eq 3) 'Incorrect resource/language job count.'
    Assert (($plan.languages -join ',') -ceq 'de-DE,fr-FR') 'Pseudo-locale included.'
    foreach ($job in $plan.jobs | Where-Object { $_.target.EndsWith('Resources.resw') }) {
        Assert ($job.keys.Count -eq 3) 'Expected changed value, comment and added key.'
        Assert ($job.keys -cnotcontains 'Stable') 'Unchanged English key selected.'
        Assert (($job.removed -join ',') -ceq 'Removed') 'Incorrect deleted keys.'
    }
    $missingJob = $plan.jobs | Where-Object { $_.target.EndsWith('Missing.resw') }
    Assert (($missingJob.keys -join ',') -ceq 'Missing') 'Missing file was not scheduled.'
    $responses = Join-Path $root 'responses'
    foreach ($language in $plan.languages) {
        $work = Join-Path $root "prepare-$language"
        & $runner -Operation Prepare -Baseline $baseline -Language $language -WorkDirectory $work
        Write-Responses $work (Join-Path $responses $language)
    }
    & $publisher -Baseline $baseline -ResponsesDirectory $responses -WorkDirectory (Join-Path $root 'apply') -ApplyOnly
    [xml]$result = Get-Content -Raw -LiteralPath $target
    Assert ($result.SelectSingleNode('/root/data[@name="Stable"]/value').InnerText -ceq "Direct3D$([char]0xa0)11") 'Unchanged NBSP lost.'
    Assert ($result.SelectSingleNode('/root/data[@name="Stable"]/comment').InnerText -ceq 'Keep this comment') 'Unchanged metadata lost.'
    Assert ($result.SelectSingleNode('/root/data[@name="Changed"]/value').InnerText -ceq 'Translated: New') 'Changed resource not applied.'
    Assert ($result.SelectSingleNode('/root/data[@name="Comment"]/comment').InnerText -ceq 'Updated comment') 'Changed comment not updated.'
    Assert ($null -eq $result.SelectSingleNode('/root/data[@name="Removed"]')) 'Deleted resource retained.'
    Assert ($null -ne $result.SelectSingleNode('/root/data[@name="Legacy"]')) 'Unrelated stale resource deleted.'
    Assert (Test-Path -LiteralPath $missingTarget) 'Missing target file not created.'
    Assert ((git rev-parse HEAD).Trim() -ceq $plan.sourceCommit) 'ApplyOnly committed changes.'

    $race = Join-Path $root 'race'
    & $translator -Operation Prepare -SourcePath $source -TargetPath $target -TargetLanguage de-DE `
        -WorkDirectory $race -Incremental -ResourceIds @()
    Add-Content -LiteralPath $target ' '
    Expect-Failure { & $translator -Operation Complete -WorkDirectory $race } 'Target changed since Prepare'
    # Delete-only updates have no model batches and preserve all remaining keys.
    $deleteWork = Join-Path $root 'delete-only'
    & $translator -Operation Prepare -SourcePath $source -TargetPath $target -TargetLanguage de-DE `
        -WorkDirectory $deleteWork -Incremental -RemovedIds Legacy
    $deleteManifest = Get-Content -Raw (Join-Path $deleteWork 'manifest.json') | ConvertFrom-Json
    Assert ($deleteManifest.batches.Count -eq 0) 'Deletion-only run created model batches.'
    & $translator -Operation Complete -WorkDirectory $deleteWork
    [xml]$deleted = Get-Content -Raw -LiteralPath $target
    Assert ($null -eq $deleted.SelectSingleNode('/root/data[@name="Legacy"]')) 'Explicit deletion not applied.'
    Assert ($deleted.SelectSingleNode('/root/data[@name="Stable"]/value').InnerText -ceq "Direct3D$([char]0xa0)11") 'Delete-only run changed existing translation.'

    $badWork = Join-Path $root 'bad'
    & $runner -Operation Prepare -Baseline $baseline -Language de-DE -WorkDirectory $badWork
    $job = $plan.jobs | Where-Object { $_.language -eq 'de-DE' -and $_.target.EndsWith('Resources.resw') }
    $badDirectory = Join-Path $root 'bad-responses'
    Write-Fixture (Join-Path (Join-Path $badDirectory $job.id) 'batch-001.output.json') '[{"id":"Unexpected","value":"bad"}]'
    $hash = (Get-FileHash -LiteralPath $target).Hash
    Expect-Failure {
        & $runner -Operation Complete -Baseline $baseline -Language de-DE -WorkDirectory $badWork -ResponsesDirectory $badDirectory
    } 'Unexpected ID'
    Assert ((Get-FileHash -LiteralPath $target).Hash -ceq $hash) 'Invalid artifact modified target.'

    $cliWork = Join-Path $root 'mock-cli'
    & $runner -Operation Prepare -Baseline $baseline -Language de-DE -WorkDirectory $cliWork
    $global:localizationTestCliCalls = 0
    function global:copilot {
        $arguments = @($args)
        $prompt = $arguments[[array]::IndexOf($arguments, '-p') + 1]
        $inputPath = [regex]::Match($prompt, '(?m)^Read input: (.+)$').Groups[1].Value.Trim()
        $outputPath = [regex]::Match($prompt, '(?m)^Write JSON response only to: (.+)$').Groups[1].Value.Trim()
        $inputBatch = Get-Content -Raw -LiteralPath $inputPath | ConvertFrom-Json
        $response = @($inputBatch.entries | ForEach-Object { @{ id = $_.id; value = 'Translated: ' + $_.source } })
        ConvertTo-Json -InputObject $response | Set-Content -LiteralPath $outputPath
        $global:localizationTestCliCalls++
        $global:LASTEXITCODE = 0
    }
    & $runner -Operation Translate -Baseline $baseline -Language de-DE -WorkDirectory $cliWork
    Assert ($global:localizationTestCliCalls -eq 1) 'CLI was not called once per batch.'
    & $runner -Operation Translate -Baseline $baseline -Language de-DE -WorkDirectory $cliWork
    Assert ($global:localizationTestCliCalls -eq 1) 'Resume retranslates successful batches.'
    Remove-Item -LiteralPath Function:\copilot
    Remove-Variable -Name localizationTestCliCalls -Scope Global

    # Publication uses a local bare remote, exercising creation and fast-forward history.
    $remote = Join-Path $root 'remote.git'
    git init --quiet --bare $remote
    git remote add origin $remote
    Remove-Item -LiteralPath $missingTarget
    $publicationResponses = Join-Path $root 'publication-responses'
    foreach ($language in $plan.languages) {
        $work = Join-Path $root "publish-prepare-$language"
        & $runner -Operation Prepare -Baseline $baseline -Language $language -WorkDirectory $work
        Write-Responses $work (Join-Path $publicationResponses $language)
    }
    & $publisher -Baseline $baseline -ResponsesDirectory $publicationResponses -WorkDirectory (Join-Path $root 'publication-1')
    $branch = 'refs/heads/dev/lhecker/llm-localization-test'
    $firstTip = (git --git-dir=$remote rev-parse $branch).Trim()
    Assert ($firstTip -cne $plan.sourceCommit) 'Publication did not create a translation commit.'
    [xml]$published = (git --git-dir=$remote show "${branch}:src/Test/Resources/de-DE/Resources.resw") -join "`n"
    Assert ($published.SelectSingleNode('/root/data[@name="Changed"]/value').InnerText -ceq 'Translated: New') 'Published wrong values.'
    $initialPaths = @(git --git-dir=$remote ls-tree -r --name-only $branch)
    Assert ($initialPaths -ccontains 'src/Test/Resources/de-DE/Missing.resw') 'Publication did not create missing target.'
    Assert ((git rev-parse HEAD).Trim() -ceq $plan.sourceCommit) 'Publication changed the source branch HEAD.'

    # Add a new source commit and delete a whole English file.
    Write-Fixture $source ($current.Replace('<value>New</value>', '<value>Newer</value>'))
    Remove-Item -LiteralPath $missingSource
    git add -- $source $missingSource
    git commit --quiet -m next-source
    $nextResponses = Join-Path $root 'next-responses'
    foreach ($language in $plan.languages) {
        $work = Join-Path $root "next-prepare-$language"
        & $runner -Operation Prepare -Baseline $baseline -Language $language -WorkDirectory $work
        Write-Responses $work (Join-Path $nextResponses $language)
    }
    & $publisher -Baseline $baseline -ResponsesDirectory $nextResponses -WorkDirectory (Join-Path $root 'publication-2')
    $secondTip = (git --git-dir=$remote rev-parse $branch).Trim()
    git --git-dir=$remote merge-base --is-ancestor $firstTip $secondTip
    Assert ($LASTEXITCODE -eq 0 -and $firstTip -cne $secondTip) 'Existing test-branch history was not retained.'
    $publishedPaths = @(git --git-dir=$remote ls-tree -r --name-only $branch)
    Assert ($publishedPaths -cnotcontains 'src/Test/Resources/de-DE/Missing.resw') 'Deleted source file retained its target.'
    [xml]$updated = (git --git-dir=$remote show "${branch}:src/Test/Resources/de-DE/Resources.resw") -join "`n"
    Assert ($updated.SelectSingleNode('/root/data[@name="Changed"]/value').InnerText -ceq 'Translated: Newer') 'Second publication did not update translation.'
    Remove-Item -LiteralPath $french
    Remove-Item -LiteralPath (Split-Path $french)
    $missingDirectoryPlan = Join-Path $root 'missing-directory-plan'
    & $runner -Operation Plan -Baseline $baseline -WorkDirectory $missingDirectoryPlan
    $directoryPlan = Get-Content -Raw (Join-Path $missingDirectoryPlan 'plan.json') | ConvertFrom-Json
    $recreated = $directoryPlan.jobs | Where-Object { $_.language -eq 'fr-FR' -and $_.target.EndsWith('Resources.resw') }
    Assert ($recreated.keys.Count -eq 4) 'Missing locale directory was not discovered from the checkpoint.'
    Write-Output "Passed $checks incremental localization checks."
}
finally {
    if (Test-Path -LiteralPath Function:\copilot) { Remove-Item -LiteralPath Function:\copilot }
    Remove-Variable -Name localizationTestCliCalls -Scope Global -ErrorAction SilentlyContinue
    Set-Location $originalLocation
    Remove-Item -LiteralPath $root -Recurse -Force
}
