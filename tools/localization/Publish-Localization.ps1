#Requires -Version 7.0
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.

.SYNOPSIS
Revalidates response-only artifacts using trusted tools, then makes a non-force test-branch push.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$ResponsesDirectory,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [switch]$ApplyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
$runner = Join-Path $PSScriptRoot 'Invoke-Localization.ps1'
$planDirectory = Join-Path $WorkDirectory 'plan'
& $runner -Operation Plan -Baseline $Baseline -WorkDirectory $planDirectory
$plan = Get-Content -Raw -LiteralPath (Join-Path $planDirectory 'plan.json') | ConvertFrom-Json
foreach ($language in $plan.languages) {
    $work = Join-Path $WorkDirectory $language
    & $runner -Operation Prepare -Baseline $Baseline -WorkDirectory $work -Language $language
    & $runner -Operation Complete -Baseline $Baseline -WorkDirectory $work -Language $language `
        -ResponsesDirectory (Join-Path $ResponsesDirectory $language)
}
if ($ApplyOnly) { return }
if ($plan.jobs.Count -eq 0) { Write-Output 'No localization updates to publish.'; return }

$branch = 'dev/lhecker/llm-localization-test'
$remote = @(git ls-remote --heads origin "refs/heads/$branch")
$publish = Join-Path $WorkDirectory 'publish'
if ($remote.Count -gt 0) {
    git fetch --no-tags origin "refs/heads/${branch}:refs/remotes/origin/$branch"
    git worktree add --detach $publish "refs/remotes/origin/$branch"
}
else {
    git worktree add --detach $publish $plan.sourceCommit
}
try {
    git -C $publish -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' `
        merge --no-edit $plan.sourceCommit
    foreach ($job in $plan.jobs) {
        $destination = Join-Path $publish $job.relativeTarget
        if ($job.deleteFile) {
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }
            if (@(git -C $publish ls-files -- $job.relativeTarget).Count -eq 0) { continue }
        }
        else {
            [void][IO.Directory]::CreateDirectory((Split-Path $destination))
            Copy-Item -LiteralPath $job.target -Destination $destination
        }
        git -C $publish add -A -- $job.relativeTarget
    }
    $staged = @(git -C $publish diff --cached --name-only)
    if ($staged.Count -gt 0) {
        git -C $publish -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' `
            commit -m "Test incremental localization through $($plan.sourceCommit)" -m "Localization baseline: $($plan.baseline)"
    }
    # A concurrent update is rejected by this ordinary push, never overwritten.
    git -C $publish push origin "HEAD:refs/heads/$branch"
}
finally {
    # No force: retain a conflicted/dirty worktree for diagnosis rather than discard it.
    if (@(git -C $publish status --porcelain).Count -eq 0) { git worktree remove $publish }
}
