#requires -Version 5.1
<#
.SYNOPSIS
Checks that Braver's overlay merges into BraveDebloater and that the extra features patch a profile.

.DESCRIPTION
Works on temporary copies only. It never writes policies or touches real Brave profiles:
  1. Parses braver.ps1, and checks that it is ASCII (Windows PowerShell 5.1 misreads UTF-8 without a BOM).
  2. Copies BraveDebloater (a local folder, or the pinned commit downloaded from GitHub) twice and merges the overlay into one copy.
  3. Checks that upstream presets and features are unchanged, using the tool's own -List and -ListFeatures output.
  4. Runs the tool against a temporary profile and checks the Braver patches. The apply step runs only when Brave is closed,
     because the tool skips profile changes while Brave runs.

.PARAMETER UpstreamPath
An existing BraveDebloater folder. Default: download the commit pinned in braver.ps1.
#>
[CmdletBinding()]
param(
    [string]$UpstreamPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$braverPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'braver.ps1'
$failures = New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; [void]$failures.Add($Message) }
}

# ---- 1. Parse ------------------------------------------------------------------------------------
Write-Host 'braver.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($braverPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "parses without errors $(@($parseErrors | ForEach-Object { $_.Message }) -join '; ')"
$bytes = [IO.File]::ReadAllBytes($braverPath)
Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'is ASCII only'

$functions = @{}
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $functions[$definition.Name] = $definition
}
foreach ($name in @('Get-BraverOverlay', 'Merge-BraverOverlay', 'ConvertTo-UndoCommand')) {
    . ([scriptblock]::Create($functions[$name].Extent.Text))
}

# With Brave closed, Get-BraveProcesses returns nothing, and .Count on nothing throws under strict mode.
Assert-True ($functions['Invoke-Braver'].Extent.Text -notmatch '(?<!@)\(Get-BraveProcesses\)\.Count') 'never reads .Count on unwrapped Get-BraveProcesses'
. ([scriptblock]::Create($functions['Test-BraveRunning'].Extent.Text))
foreach ($case in @(@{ Name = 'closed'; Processes = @(); Expected = $false }, @{ Name = 'one process'; Processes = @('brave'); Expected = $true })) {
    $script:fakeProcesses = $case.Processes
    function Get-BraveProcesses { return @($script:fakeProcesses) }
    $running = $null
    try { $running = Test-BraveRunning } catch { $running = "threw: $($_.Exception.Message)" }
    Assert-True ($running -eq $case.Expected) "Test-BraveRunning with Brave $($case.Name) returns $($case.Expected) under strict mode (got $running)"
}


# Undo command: BraveDebloater's hint has the arguments but not the script path.
$hint = "[BraveDebloater] To undo this run, rerun BraveDebloater with: -UndoFromBackup C:\B\BraveDebloater-1.json -ProfileRoot 'C:\U\User Data' -Apply"
$undo = ConvertTo-UndoCommand -Line $hint -ScriptPath "C:\Tool's dir\Invoke-BraveDebloat.ps1"
Assert-True ($undo -eq "& 'C:\Tool''s dir\Invoke-BraveDebloat.ps1' -UndoFromBackup C:\B\BraveDebloater-1.json -ProfileRoot 'C:\U\User Data' -Apply") "undo command adds the quoted script path (got $undo)"
$undoErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($undo, [ref]$null, [ref]$undoErrors)
Assert-True (@($undoErrors).Count -eq 0) 'undo command parses as PowerShell'
$fallback = 'To undo this run, rerun BraveDebloater with -Apply and these values. Quote each path for your shell yourself, because a path contains %: -UndoFromBackup = C:\%x%\b.json'
Assert-True ($null -eq (ConvertTo-UndoCommand -Line $fallback -ScriptPath 'C:\t.ps1')) 'unquotable fallback hint is left to BraveDebloater'
Assert-True ($null -eq (ConvertTo-UndoCommand -Line '[BraveDebloater] Set BraveRewardsDisabled.' -ScriptPath 'C:\t.ps1')) 'other lines give no undo command'

$pinMatch = [regex]::Match($functions['Invoke-Braver'].Extent.Text, "pinnedUpstreamRef = '([0-9a-f]{40})'")
Assert-True $pinMatch.Success 'pins an upstream commit'

# ---- 2. Copies -----------------------------------------------------------------------------------
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('BraverTest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    if ([string]::IsNullOrWhiteSpace($UpstreamPath)) {
        $sha = $pinMatch.Groups[1].Value
        Write-Host "Downloading osfv/BraveDebloater@$($sha.Substring(0, 12))"
        $zipPath = Join-Path $tempRoot 'upstream.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/osfv/BraveDebloater/zip/$sha" -OutFile $zipPath
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, (Join-Path $tempRoot 'download'))
        $UpstreamPath = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'download') -Directory)[0].FullName
    }
    $original = Join-Path $tempRoot 'original'
    $merged = Join-Path $tempRoot 'merged'
    foreach ($copy in @($original, $merged)) {
        New-Item -ItemType Directory -Path $copy | Out-Null
        Get-ChildItem -LiteralPath $UpstreamPath -Force | Where-Object { $_.Name -ne '.git' } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $copy -Recurse -Force }
    }

    Write-Host 'Merge'
    $result = Merge-BraverOverlay -ToolPath $merged
    Assert-True ((@($result.Added) -join ',') -eq 'SidePanelButton,BookmarksBar') "adds SidePanelButton and BookmarksBar (added: $(@($result.Added) -join ','))"
    $again = Merge-BraverOverlay -ToolPath $merged
    Assert-True (@($again.Added).Count -eq 0 -and @($again.Skipped).Count -eq 2) 'a second merge adds nothing'
    $manifest = [IO.File]::ReadAllText((Join-Path $merged 'config\policies.json')) | ConvertFrom-Json
    Assert-True (@($manifest.profilePreferencePatches | Where-Object { $_.feature -in @('SidePanelButton', 'BookmarksBar') }).Count -eq 3) 'adds three profile patches once'

    # ---- 3. Upstream unchanged -------------------------------------------------------------------
    Write-Host 'Upstream unchanged'
    # PowerShell 5.1 ConvertTo-Json rewrites the whole file, so compare with a parser that is not PowerShell's:
    # the merged manifest without the Braver entries must equal the original manifest.
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $overlayIds = @(@((Get-BraverOverlay).features) | ForEach-Object { [string]$_.id })
    $originalTree = $serializer.DeserializeObject([IO.File]::ReadAllText((Join-Path $original 'config\policies.json')))
    $mergedTree = $serializer.DeserializeObject([IO.File]::ReadAllText((Join-Path $merged 'config\policies.json')))
    # Serialized key by key and entry by entry: PowerShell wraps values it stores back into the tree in
    # PSObjects, which this serializer rejects.
    function Get-CanonicalManifest($Tree, [switch]$WithoutOverlay) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in $Tree.Keys) {
            $idKey = @{ features = 'id'; profilePreferencePatches = 'feature' }[$key]
            if ($null -eq $idKey) {
                [void]$parts.Add("$key=$($serializer.Serialize($Tree[$key]))")
                continue
            }
            foreach ($entry in $Tree[$key]) {
                if ($WithoutOverlay -and $overlayIds -contains [string]$entry[$idKey]) { continue }
                [void]$parts.Add("$key[]=$($serializer.Serialize($entry))")
            }
        }
        return ($parts -join "`n")
    }
    $originalCanonical = Get-CanonicalManifest $originalTree
    Assert-True ($originalCanonical -eq (Get-CanonicalManifest $mergedTree -WithoutOverlay)) 'manifest without the Braver entries equals the original'
    Assert-True ($originalCanonical -ne (Get-CanonicalManifest $mergedTree)) 'manifest comparison sees the Braver entries'

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Invoke-ToolText([string]$ToolPath, [string[]]$Arguments) {
        $script = Join-Path $ToolPath 'Invoke-BraveDebloat.ps1'
        $ErrorActionPreference = 'Continue'
        $text = (& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $script @Arguments 2>&1 | Out-String -Width 4096)
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    }
    # The tool's text tables size their columns to the longest entry, so only check that it still runs.
    $missingProfileRoot = Join-Path $tempRoot 'NoProfiles'
    foreach ($preset in @('Core', 'Standard', 'Extreme')) {
        $arguments = @('-Platform', 'Windows', '-Preset', $preset, '-List', '-IncludeProfilePreferences', '-ProfileRoot', $missingProfileRoot)
        $after = Invoke-ToolText -ToolPath $merged -Arguments $arguments
        Assert-True ($after.ExitCode -eq 0) "-Preset $preset -List runs (exit $($after.ExitCode))"
    }
    $after = Invoke-ToolText -ToolPath $merged -Arguments @('-ListFeatures')
    Assert-True ($after.ExitCode -eq 0 -and $after.Text -match 'SidePanelButton' -and $after.Text -match 'BookmarksBar') '-ListFeatures shows the Braver features'

    # ---- 4. Temporary profile --------------------------------------------------------------------
    Write-Host 'Profile patches'
    $profileRoot = Join-Path $tempRoot 'User Data'
    $profileDirectory = Join-Path $profileRoot 'Default'
    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    $preferencesPath = Join-Path $profileDirectory 'Preferences'
    [IO.File]::WriteAllText($preferencesPath, '{"brave":{"show_side_panel_button":true},"bookmark_bar":{}}', (New-Object System.Text.UTF8Encoding($false)))
    $policyPath = Join-Path $tempRoot 'policy.json'
    $backupDirectory = Join-Path $tempRoot 'backups'
    $arguments = @('-Platform', 'Linux', '-PolicyPath', $policyPath, '-OnlyFeature', 'SidePanelButton,BookmarksBar', '-IncludeProfilePreferences', '-ProfileRoot', $profileRoot, '-BackupDirectory', $backupDirectory)
    $dryRun = Invoke-ToolText -ToolPath $merged -Arguments $arguments
    Assert-True ($dryRun.ExitCode -eq 0) "dry run succeeds (exit $($dryRun.ExitCode))"
    foreach ($path in @('brave.show_side_panel_button', 'brave.show_bookmarks_button', 'bookmark_bar.show_on_all_tabs')) {
        Assert-True ($dryRun.Text -match [regex]::Escape($path)) "dry run plans $path"
    }

    # Policy-only apply and undo into a temporary policy file. Runs even while Brave is open.
    $policyOnlyPath = Join-Path $tempRoot 'policy-only.json'
    $policyOnlyRun = Invoke-ToolText -ToolPath $merged -Arguments @('-Platform', 'Linux', '-PolicyPath', $policyOnlyPath, '-OnlyFeature', 'Rewards', '-BackupDirectory', $backupDirectory, '-Apply')
    $policyOnlyUndo = @($policyOnlyRun.Text -split "`r?`n" | ForEach-Object { ConvertTo-UndoCommand -Line $_ -ScriptPath (Join-Path $merged 'Invoke-BraveDebloat.ps1') } | Where-Object { $null -ne $_ })
    Assert-True ($policyOnlyRun.ExitCode -eq 0 -and (Test-Path -LiteralPath $policyOnlyPath) -and $policyOnlyUndo.Count -eq 1) 'policy-only apply writes the policy and yields one undo command'
    if ($policyOnlyUndo.Count -eq 1) {
        $ErrorActionPreference = 'Continue'
        $undoText = (& $powershellPath -NoProfile -ExecutionPolicy Bypass -Command $policyOnlyUndo[0] 2>&1 | Out-String -Width 4096)
        $undoExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $policyLeft = (Test-Path -LiteralPath $policyOnlyPath) -and ([IO.File]::ReadAllText($policyOnlyPath) -match 'BraveRewardsDisabled')
        Assert-True ($undoExit -eq 0 -and -not $policyLeft) "policy-only undo command removes the policy (exit $undoExit) $(if ($undoExit -ne 0 -or $policyLeft) { $undoText })"
    }

    if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Host '  skip apply: Brave is running, and the tool skips profile changes while it runs.' -ForegroundColor Yellow
    }
    else {
        $applyRun = Invoke-ToolText -ToolPath $merged -Arguments ($arguments + @('-Apply'))
        Assert-True ($applyRun.ExitCode -eq 0) "apply succeeds (exit $($applyRun.ExitCode))"
        $preferences = [IO.File]::ReadAllText($preferencesPath) | ConvertFrom-Json
        Assert-True ($preferences.brave.show_side_panel_button -eq $false) 'side panel button hidden'
        Assert-True ($preferences.brave.show_bookmarks_button -eq $true) 'bookmarks button shown'
        Assert-True ($preferences.bookmark_bar.show_on_all_tabs -eq $true) 'bookmarks bar on all tabs'

        # Run the undo command exactly as Braver would print it.
        $mergedScript = Join-Path $merged 'Invoke-BraveDebloat.ps1'
        $undoCommands = @($applyRun.Text -split "`r?`n" | ForEach-Object { ConvertTo-UndoCommand -Line $_ -ScriptPath $mergedScript } | Where-Object { $null -ne $_ })
        Assert-True ($undoCommands.Count -eq 1) 'apply output yields one undo command'
        if ($undoCommands.Count -eq 1) {
            $ErrorActionPreference = 'Continue'
            $undoText = (& $powershellPath -NoProfile -ExecutionPolicy Bypass -Command $undoCommands[0] 2>&1 | Out-String -Width 4096)
            $undoExit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            Assert-True ($undoExit -eq 0) "undo command succeeds (exit $undoExit) $(if ($undoExit -ne 0) { $undoText })"
            $restored = [IO.File]::ReadAllText($preferencesPath) | ConvertFrom-Json
            Assert-True ($restored.brave.show_side_panel_button -eq $true -and $null -eq $restored.brave.PSObject.Properties['show_bookmarks_button'] -and $null -eq $restored.bookmark_bar.PSObject.Properties['show_on_all_tabs']) 'undo restores the original profile'
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
