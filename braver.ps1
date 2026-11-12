#requires -Version 5.1
<#
.SYNOPSIS
Debloats Brave on this Windows PC in one go: machine-wide policies for every user, plus profile settings for every Brave profile.

.DESCRIPTION
Braver is a wrapper around BraveDebloater (https://github.com/osfv/BraveDebloater). Run it from an elevated PowerShell window:

    irm https://raw.githubusercontent.com/doerofthedo/braver/main/braver.ps1 | iex

What it does:
  1. Checks for Windows and administrator rights. If PowerShell is not elevated, it explains why and offers to reopen itself as administrator.
  2. Downloads BraveDebloater, pinned to a tested commit, into %LOCALAPPDATA%\Braver\tool, and adds Braver's extra profile features to it.
  3. Finds every Windows user's Brave profiles. If Brave is open, it asks to close Brave (or waits, or skips the profile part).
  4. Shows a preview, asks for confirmation, then applies the policies (HKLM) and patches every profile's Preferences file.

Every apply run writes a backup to %LOCALAPPDATA%\Braver\backups and a log to %LOCALAPPDATA%\Braver\logs.

Options (pass them by turning the download into a script block):

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/doerofthedo/braver/main/braver.ps1))) -PreviewOnly

.PARAMETER PreviewOnly
Show what would change and stop. Nothing is written. Works without administrator rights, but then only the profiles of the current Windows user can be read.

.PARAMETER Yes
Do not ask questions. Applies without confirmation. If Brave is open, profile settings are skipped (policies are still applied).

.PARAMETER UpstreamRef
Branch, tag, or commit of BraveDebloater to download. Default: the commit Braver was tested against.

.PARAMETER UpstreamRepository
GitHub repository to download BraveDebloater from. Default: osfv/BraveDebloater.

.PARAMETER LocalToolPath
Use an existing BraveDebloater folder instead of downloading one. It is copied, not changed. For testing.
#>
[CmdletBinding()]
param(
    [switch]$PreviewOnly,

    [switch]$Yes,

    [string]$UpstreamRef,

    [string]$UpstreamRepository,

    [string]$LocalToolPath
)

function Invoke-Braver {
    [CmdletBinding()]
    param(
        [switch]$PreviewOnly,
        [switch]$Yes,
        [string]$UpstreamRef,
        [string]$UpstreamRepository,
        [string]$LocalToolPath
    )

    # Everything lives inside this function so `irm | iex` leaves the caller's session settings alone.
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # ---- Upstream pin ------------------------------------------------------------------------------
    # BraveDebloater 0.9.1 plus Brave policy templates 158.1.101.36. Bump after testing a newer commit.
    $pinnedUpstreamRef = '7b8956384be976d5521ac255e85cbe3392c90729'
    if ([string]::IsNullOrWhiteSpace($UpstreamRef)) { $UpstreamRef = $pinnedUpstreamRef }
    if ([string]::IsNullOrWhiteSpace($UpstreamRepository)) { $UpstreamRepository = 'osfv/BraveDebloater' }

    # ---- Debloat selection -------------------------------------------------------------------------
    # Standard preset: Rewards, Wallet, VPN, LeoAI, News, Talk, Playlist, EmailAliases, Speedreader,
    # Wayback, BraveTelemetry, plus the NewTabBackgrounds profile patch (sponsored new tab images).
    # SidePanelButton and BookmarksBar are Braver's own features, added by Get-BraverOverlay below.
    $preset = 'Standard'
    $includeFeatures = @(
        'ChromiumTelemetry',
        'SearchSuggestions',
        'RemoteSpellcheck',
        'Promotions',
        'MediaRecommendations',
        'ShoppingList',
        'QRCodeGenerator',
        'GoogleSearchSidePanel',
        'SidePanelButton',
        'BookmarksBar'
    )
    # ---------------------------------------------------------------------------------------------

    $braverUrl = 'https://raw.githubusercontent.com/doerofthedo/braver/main/braver.ps1'
    $baseDirectory = Join-Path $env:LOCALAPPDATA 'Braver'
    $toolDirectory = Join-Path $baseDirectory 'tool'
    $backupDirectory = Join-Path $baseDirectory 'backups'
    $logDirectory = Join-Path $baseDirectory 'logs'

    function Write-Info([string]$Message) { Write-Host "[Braver] $Message" }
    function Write-Good([string]$Message) { Write-Host "[Braver] $Message" -ForegroundColor Green }
    function Write-Attention([string]$Message) { Write-Host "[Braver] $Message" -ForegroundColor Yellow }
    function Write-Title([string]$Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }

    function Get-BraverOverlay {
        # Extra features merged into BraveDebloater's config/policies.json. They are profile-only:
        # no policies and no preset, so they run only when named in -IncludeFeature together with
        # -IncludeProfilePreferences. Users can change them again in brave://settings/appearance.
        # Checked against a Brave 157 Windows profile: none of these paths is listed under the
        # PreferenceMACs key of Secure Preferences, so Brave does not reset them as tampering.
        return [pscustomobject]@{
            features                 = @(
                [pscustomobject]@{
                    id             = 'SidePanelButton'
                    label          = 'side panel toolbar button'
                    policies       = @()
                    defaultPresets = @()
                    reason         = 'Hide the side panel toolbar button in profile preferences. Users can show it again.'
                },
                [pscustomobject]@{
                    id             = 'BookmarksBar'
                    label          = 'bookmarks bar and bookmarks button'
                    policies       = @()
                    defaultPresets = @()
                    reason         = 'Show the bookmarks bar on all tabs and the bookmarks toolbar button in profile preferences. Users can hide them again.'
                }
            )
            profilePreferencePatches = @(
                [pscustomobject]@{
                    feature       = 'SidePanelButton'
                    path          = 'brave.show_side_panel_button'
                    value         = $false
                    createMissing = $true
                    reason        = 'Hide the side panel toolbar button.'
                },
                [pscustomobject]@{
                    feature       = 'BookmarksBar'
                    path          = 'brave.show_bookmarks_button'
                    value         = $true
                    createMissing = $true
                    reason        = 'Show the bookmarks toolbar button.'
                },
                [pscustomobject]@{
                    feature       = 'BookmarksBar'
                    path          = 'bookmark_bar.show_on_all_tabs'
                    value         = $true
                    createMissing = $true
                    reason        = 'Show the bookmarks bar on all tabs, not only on the new tab page.'
                }
            )
        }
    }

    function Merge-BraverOverlay {
        # Adds the overlay features and their profile patches to the tool copy's manifest. A feature
        # id that upstream already defines is left to upstream, together with its patches.
        param([Parameter(Mandatory = $true)][string]$ToolPath)

        $manifestPath = Join-Path (Join-Path $ToolPath 'config') 'policies.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $overlay = Get-BraverOverlay

        $knownIds = @{}
        $features = New-Object System.Collections.Generic.List[object]
        foreach ($feature in @($manifest.features)) {
            $knownIds[[string]$feature.id] = $true
            [void]$features.Add($feature)
        }
        $patches = New-Object System.Collections.Generic.List[object]
        foreach ($patch in @($manifest.profilePreferencePatches)) {
            [void]$patches.Add($patch)
        }

        $added = New-Object System.Collections.Generic.List[string]
        $skipped = New-Object System.Collections.Generic.List[string]
        foreach ($feature in @($overlay.features)) {
            if ($knownIds.ContainsKey([string]$feature.id)) {
                [void]$skipped.Add([string]$feature.id)
                continue
            }
            [void]$features.Add($feature)
            [void]$added.Add([string]$feature.id)
        }
        foreach ($patch in @($overlay.profilePreferencePatches)) {
            if ($added -contains [string]$patch.feature) {
                [void]$patches.Add($patch)
            }
        }

        $manifest.features = $features.ToArray()
        $manifest.profilePreferencePatches = $patches.ToArray()
        $json = ConvertTo-Json -InputObject $manifest -Depth 100
        [IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))

        return [pscustomobject]@{ Added = $added.ToArray(); Skipped = $skipped.ToArray() }
    }

    function Read-Choice {
        # $Default answers an empty Enter. $SafeAnswer is used when nobody can answer (input is
        # redirected or closed), so an unattended run never elevates, closes Brave, or applies.
        param([string]$Prompt, [string[]]$Allowed, [string]$Default, [string]$SafeAnswer)
        $inputRedirected = $false
        try { $inputRedirected = [Console]::IsInputRedirected } catch { $inputRedirected = $false }
        if ($inputRedirected) {
            Write-Attention "$Prompt -> no keyboard input available, answering '$SafeAnswer'."
            return $SafeAnswer
        }
        while ($true) {
            $answer = Read-Host $Prompt
            if ($null -eq $answer) {
                return $SafeAnswer
            }
            $answer = $answer.Trim().ToUpperInvariant()
            if ($answer -eq '') { return $Default }
            if ($Allowed -contains $answer) { return $answer }
            Write-Attention "Please answer $($Allowed -join ' or ')."
        }
    }

    function Test-IsAdministrator {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Get-BraveProcesses {
        # Callers must wrap this in @(): with no process running it returns nothing, and .Count on
        # nothing throws under strict mode. Use Test-BraveRunning for a plain yes/no.
        return @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue)
    }

    function Test-BraveRunning {
        return (@(Get-BraveProcesses).Count -gt 0)
    }

    function Get-BraveUserDataRoots {
        # Every local user profile folder, including users who are signed out, from the registry ProfileList.
        $roots = New-Object System.Collections.Generic.List[object]
        $profileList = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        foreach ($entry in @(Get-ChildItem -LiteralPath $profileList -ErrorAction SilentlyContinue)) {
            # Real user accounts have S-1-5-21-... SIDs; skip SYSTEM, LOCAL SERVICE, and NETWORK SERVICE.
            if ($entry.PSChildName -notlike 'S-1-5-21-*') { continue }
            $imagePath = [string](Get-ItemProperty -LiteralPath $entry.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
            if ([string]::IsNullOrWhiteSpace($imagePath)) { continue }
            $imagePath = [Environment]::ExpandEnvironmentVariables($imagePath)
            $userData = Join-Path $imagePath 'AppData\Local\BraveSoftware\Brave-Browser\User Data'
            if (-not (Test-Path -LiteralPath $userData)) { continue }
            $profiles = @(Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') } |
                    ForEach-Object { $_.Name })
            if ($profiles.Count -eq 0) { continue }
            [void]$roots.Add([pscustomobject]@{
                    User     = Split-Path -Leaf $imagePath
                    Path     = $userData
                    Profiles = $profiles
                })
        }
        return $roots.ToArray()
    }

    function Test-BraveInstalled {
        $candidates = New-Object System.Collections.Generic.List[string]
        foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
                [void]$candidates.Add((Join-Path $programFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'))
            }
        }
        foreach ($userRoot in @(Get-ChildItem -LiteralPath (Split-Path -Parent $env:USERPROFILE) -Directory -ErrorAction SilentlyContinue)) {
            [void]$candidates.Add((Join-Path $userRoot.FullName 'AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe'))
        }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) { return $true }
        }
        return $false
    }

    function Close-Brave {
        # Ask every Brave window to close first, so Brave shuts down cleanly and restores tabs next time.
        foreach ($process in (Get-BraveProcesses)) {
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                [void]$process.CloseMainWindow()
            }
        }
        $deadline = (Get-Date).AddSeconds(15)
        while ((Test-BraveRunning) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        $remaining = @(Get-BraveProcesses)
        if ($remaining.Count -gt 0) {
            Write-Attention "Brave did not close within 15 seconds. Stopping $($remaining.Count) Brave process(es)."
            $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        return (-not (Test-BraveRunning))
    }

    function Get-ToolSource {
        param([string]$Repository, [string]$Ref)

        # Resolve the ref to one commit so the whole run uses the same code, and so the log says which.
        $sha = $null
        if ($Ref -match '^[0-9a-f]{40}$') {
            $sha = $Ref
        }
        else {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$Repository/commits/$Ref" -Headers @{ Accept = 'application/vnd.github.sha' }
                $content = [string]$response.Content
                if ($content -match '^[0-9a-f]{40}$') { $sha = $content }
            }
            catch {
                Write-Attention "Could not look up the commit for '$Ref' ($($_.Exception.Message)). Downloading '$Ref' directly."
            }
        }
        if ($null -ne $sha) {
            return [pscustomobject]@{ Label = "$Repository@$($sha.Substring(0, 12))"; Url = "https://codeload.github.com/$Repository/zip/$sha" }
        }
        return [pscustomobject]@{ Label = "$Repository@$Ref"; Url = "https://codeload.github.com/$Repository/zip/$Ref" }
    }

    function Reset-ToolDirectory {
        param([string]$Destination)
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    }

    function Install-Tool {
        param($Source, [string]$Destination)

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("Braver-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $zipPath = Join-Path $tempRoot 'source.zip'
            Invoke-WebRequest -UseBasicParsing -Uri $Source.Url -OutFile $zipPath
            $extractRoot = Join-Path $tempRoot 'extract'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractRoot)

            $sourceFolder = @(Get-ChildItem -LiteralPath $extractRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Invoke-BraveDebloat.ps1') })
            if ($sourceFolder.Count -ne 1) {
                throw "The download from $($Source.Url) does not contain Invoke-BraveDebloat.ps1. Nothing was changed."
            }
            Reset-ToolDirectory -Destination $Destination
            Move-Item -LiteralPath $sourceFolder[0].FullName -Destination $Destination
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Copy-LocalTool {
        param([string]$Source, [string]$Destination)
        Reset-ToolDirectory -Destination $Destination
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force | Where-Object { $_.Name -ne '.git' })) {
            Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
        }
    }

    function ConvertTo-UndoCommand {
        # BraveDebloater prints "To undo this run, rerun BraveDebloater with: <arguments>", with the
        # arguments already quoted for PowerShell. Turn that into a command that can be pasted as is.
        # Returns $null for any other line, including BraveDebloater's fallback for paths it cannot quote.
        param([string]$Line, [string]$ScriptPath)
        $match = [regex]::Match($Line, 'To undo this run, rerun BraveDebloater with: (-UndoFromBackup .+ -Apply)\s*$')
        if (-not $match.Success) { return $null }
        return "& '$($ScriptPath -replace "'", "''")' $($match.Groups[1].Value)"
    }

    function Invoke-Tool {
        param([string]$ScriptPath, [string[]]$Arguments)

        # A separate Windows PowerShell process: the execution policy cannot block the downloaded
        # script, and the tool's strict mode and errors stay out of this session.
        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
        # Windows PowerShell 5.1 turns a native command's stderr line into a terminating error when
        # $ErrorActionPreference is Stop. Show the tool's errors as text and judge by the exit code.
        $ErrorActionPreference = 'Continue'
        $state = @{ UndoCommand = $null }
        & $powershellPath @allArguments 2>&1 | ForEach-Object {
            $line = [string]$_
            $lineUndo = ConvertTo-UndoCommand -Line $line -ScriptPath $ScriptPath
            if ($null -ne $lineUndo) {
                # Shown complete in the summary instead; the tool's own hint leaves out the script path.
                $state.UndoCommand = $lineUndo
                Write-Host '  [Braver] Backup made. The undo command is shown at the end.'
            }
            else {
                Write-Host "  $line"
            }
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; UndoCommand = $state.UndoCommand }
    }

    # ---- 1. Checks ---------------------------------------------------------------------------------
    Write-Title 'Braver: Brave debloat'

    if ($env:OS -ne 'Windows_NT') {
        Write-Attention 'Braver is for Windows. On macOS or Linux, use BraveDebloater directly. Nothing was changed.'
        return
    }

    $isAdministrator = Test-IsAdministrator
    if (-not $isAdministrator -and $PreviewOnly) {
        Write-Attention 'Not running as administrator. The preview can only read your own Brave profiles.'
    }
    elseif (-not $isAdministrator) {
        Write-Attention 'Administrator rights are needed.'
        Write-Info 'Braver writes Brave policies for the whole PC (HKEY_LOCAL_MACHINE) and edits the Brave'
        Write-Info 'profiles of every Windows user. Windows only allows that from an elevated PowerShell window.'
        Write-Info 'Nothing was changed.'
        if ($Yes) {
            Write-Info 'Open PowerShell with "Run as administrator", then run the same command again.'
            return
        }
        $answer = Read-Choice -Prompt 'Reopen Braver as administrator now? A Windows prompt will ask for permission. [Y/n]' -Allowed @('Y', 'N') -Default 'Y' -SafeAnswer 'N'
        if ($answer -ne 'Y') {
            Write-Info 'Open PowerShell with "Run as administrator", then run the same command again.'
            return
        }
        $forwarded = " -UpstreamRef '$($UpstreamRef -replace "'", "''")' -UpstreamRepository '$($UpstreamRepository -replace "'", "''")'"
        $localScript = $PSCommandPath
        if (-not [string]::IsNullOrWhiteSpace($localScript) -and (Split-Path -Leaf $localScript) -eq 'braver.ps1' -and (Test-Path -LiteralPath $localScript)) {
            # Started from a saved copy: reopen that same file.
            $command = "& '$($localScript -replace "'", "''")'$forwarded"
            if (-not [string]::IsNullOrWhiteSpace($LocalToolPath)) {
                $command += " -LocalToolPath '$($LocalToolPath -replace "'", "''")'"
            }
        }
        else {
            $command = "& ([scriptblock]::Create((irm '$braverUrl')))$forwarded"
        }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        try {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) | Out-Null
            Write-Good 'Continuing in the new administrator window. You can close this one.'
        }
        catch {
            Write-Attention 'The administrator prompt was cancelled. Nothing was changed.'
            Write-Info 'Open PowerShell with "Run as administrator", then run the same command again.'
        }
        return
    }

    if (-not (Test-BraveInstalled)) {
        Write-Attention 'Brave was not found on this PC.'
        Write-Info 'Policies can still be set now; Brave applies them once it is installed.'
        if (-not $Yes -and -not $PreviewOnly) {
            $answer = Read-Choice -Prompt 'Continue anyway? [y/N]' -Allowed @('Y', 'N') -Default 'N' -SafeAnswer 'N'
            if ($answer -ne 'Y') {
                Write-Info 'Stopped. Nothing was changed.'
                return
            }
        }
    }

    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $logPath = Join-Path $logDirectory ("braver-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $transcriptStarted = $false
    try {
        Start-Transcript -LiteralPath $logPath -Force | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Attention "Could not start the log at $logPath. Continuing without a log."
    }

    try {
        # ---- 2. Download -----------------------------------------------------------------------------
        Write-Title 'Getting BraveDebloater'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch {
            Write-Verbose 'TLS 1.2 is already enabled or cannot be changed.'
        }
        if (-not [string]::IsNullOrWhiteSpace($LocalToolPath)) {
            if (-not (Test-Path -LiteralPath (Join-Path $LocalToolPath 'Invoke-BraveDebloat.ps1'))) {
                Write-Attention "No Invoke-BraveDebloat.ps1 in $LocalToolPath. Nothing was changed."
                return
            }
            Copy-LocalTool -Source $LocalToolPath -Destination $toolDirectory
            Write-Good "Copied the local BraveDebloater in $LocalToolPath to $toolDirectory (no download)."
        }
        else {
            $source = Get-ToolSource -Repository $UpstreamRepository -Ref $UpstreamRef
            Install-Tool -Source $source -Destination $toolDirectory
            Write-Good "Downloaded $($source.Label) to $toolDirectory"
            if ($UpstreamRef -ne $pinnedUpstreamRef) {
                Write-Attention "Using '$UpstreamRef' instead of the commit Braver was tested against."
            }
        }
        $toolScript = Join-Path $toolDirectory 'Invoke-BraveDebloat.ps1'

        $merge = Merge-BraverOverlay -ToolPath $toolDirectory
        if ($merge.Added.Count -gt 0) {
            Write-Good "Added Braver features: $($merge.Added -join ', ')"
        }
        if ($merge.Skipped.Count -gt 0) {
            Write-Attention "BraveDebloater already defines $($merge.Skipped -join ', '). Using its definition."
        }

        # ---- 3. Profiles and Brave state -------------------------------------------------------------
        Write-Title 'Brave profiles'
        $userDataRoots = @(Get-BraveUserDataRoots)
        if ($userDataRoots.Count -eq 0) {
            Write-Info 'No Brave profiles found. Only the policies will be applied.'
        }
        foreach ($root in $userDataRoots) {
            Write-Info "User $($root.User): $($root.Profiles -join ', ')"
        }

        $includeProfiles = $userDataRoots.Count -gt 0
        if ($includeProfiles -and -not $PreviewOnly -and (Test-BraveRunning)) {
            Write-Attention 'Brave is open. Profile settings can only be changed while Brave is closed.'
            Write-Info 'Policies are applied either way.'
            if ($Yes) {
                Write-Attention 'Skipping profile settings because -Yes was used. Close Brave and run again to apply them.'
                $includeProfiles = $false
            }
            else {
                Write-Info '  [C] Close Brave now. Open tabs come back if Brave is set to continue where you left off.'
                Write-Info '      Unsaved text in open pages may be lost.'
                Write-Info '  [W] Wait while I close Brave myself.'
                Write-Info '  [S] Skip profile settings this time.'
                $answer = Read-Choice -Prompt 'Your choice [C/W/S]' -Allowed @('C', 'W', 'S') -Default 'W' -SafeAnswer 'S'
                if ($answer -eq 'C') {
                    if (Close-Brave) {
                        Write-Good 'Brave is closed.'
                    }
                    else {
                        Write-Attention 'Brave is still running. Skipping profile settings.'
                        $includeProfiles = $false
                    }
                }
                elseif ($answer -eq 'W') {
                    while (Test-BraveRunning) {
                        $wait = Read-Choice -Prompt 'Close all Brave windows (also the tray icon), then press Enter. Type S to skip profile settings' -Allowed @('S') -Default '' -SafeAnswer 'S'
                        if ($wait -eq 'S') {
                            $includeProfiles = $false
                            break
                        }
                        if (Test-BraveRunning) {
                            Write-Attention 'Brave is still running.'
                        }
                    }
                    if ($includeProfiles) {
                        Write-Good 'Brave is closed.'
                    }
                }
                else {
                    $includeProfiles = $false
                }
            }
        }

        # ---- 4. Preview --------------------------------------------------------------------------------
        $baseArguments = @('-Preset', $preset, '-IncludeFeature', ($includeFeatures -join ','), '-Scope', 'LocalMachine', '-BackupDirectory', $backupDirectory)
        $runs = New-Object System.Collections.Generic.List[object]
        if ($includeProfiles) {
            foreach ($root in $userDataRoots) {
                [void]$runs.Add([pscustomobject]@{ Label = "policies and profiles of $($root.User)"; Arguments = ($baseArguments + @('-IncludeProfilePreferences', '-ProfileRoot', $root.Path)) })
            }
        }
        else {
            [void]$runs.Add([pscustomobject]@{ Label = 'policies'; Arguments = $baseArguments })
        }

        Write-Title 'Preview (nothing is changed yet)'
        foreach ($run in $runs) {
            Write-Info "Preview: $($run.Label)"
            $result = Invoke-Tool -ScriptPath $toolScript -Arguments $run.Arguments
            if ($result.ExitCode -ne 0) {
                Write-Attention "The preview failed (exit code $($result.ExitCode)). Nothing was changed. See the messages above."
                return
            }
        }

        if ($PreviewOnly) {
            Write-Title 'Done'
            Write-Good 'Preview only. Nothing was changed.'
            return
        }

        if (-not $Yes) {
            $answer = Read-Choice -Prompt 'Apply these changes? [y/N]' -Allowed @('Y', 'N') -Default 'N' -SafeAnswer 'N'
            if ($answer -ne 'Y') {
                Write-Info 'Stopped. Nothing was changed.'
                return
            }
        }

        # ---- 5. Apply ----------------------------------------------------------------------------------
        Write-Title 'Applying'
        $failed = 0
        $undoCommands = New-Object System.Collections.Generic.List[object]
        foreach ($run in $runs) {
            Write-Info "Applying: $($run.Label)"
            $result = Invoke-Tool -ScriptPath $toolScript -Arguments ($run.Arguments + @('-Apply'))
            if ($result.ExitCode -ne 0) {
                $failed++
                Write-Attention "Applying $($run.Label) failed (exit code $($result.ExitCode)). See the messages above."
            }
            if ($null -ne $result.UndoCommand) {
                [void]$undoCommands.Add([pscustomobject]@{ Label = $run.Label; Command = $result.UndoCommand })
            }
        }

        # ---- 6. Summary --------------------------------------------------------------------------------
        Write-Title 'Done'
        if ($failed -eq 0) {
            Write-Good 'Brave debloat applied.'
        }
        else {
            Write-Attention "$failed of $($runs.Count) run(s) failed. The others were applied."
        }
        if (-not $includeProfiles -and $userDataRoots.Count -gt 0) {
            Write-Attention 'Profile settings were skipped. Close Brave and run Braver again to apply them.'
        }

        Write-Host ''
        Write-Info 'Next:'
        Write-Info '  1. Start Brave (or restart it if it is open) so it loads the new policies.'
        Write-Info '  2. Open brave://policy to check them. Locked settings show greyed out in brave://settings.'

        Write-Host ''
        if ($undoCommands.Count -gt 0) {
            Write-Info 'To undo: close Brave, open PowerShell with "Run as administrator", and paste:'
            foreach ($undo in $undoCommands) {
                if ($undoCommands.Count -gt 1) { Write-Info "  ($($undo.Label))" }
                Write-Host "    $($undo.Command)" -ForegroundColor Cyan
            }
        }
        else {
            Write-Info 'To undo: see the restore instructions BraveDebloater printed above.'
        }
        Write-Info "Backups are kept in $backupDirectory"
        if ($transcriptStarted) {
            Write-Info "Full log (also has the undo command): $logPath"
        }
    }
    finally {
        if ($transcriptStarted) {
            try { Stop-Transcript | Out-Null } catch { Write-Verbose 'Transcript was already stopped.' }
        }
    }
}

$braverParameters = @{ UpstreamRef = $UpstreamRef; UpstreamRepository = $UpstreamRepository }
if ($PreviewOnly) { $braverParameters['PreviewOnly'] = $true }
if ($Yes) { $braverParameters['Yes'] = $true }
if (-not [string]::IsNullOrWhiteSpace($LocalToolPath)) { $braverParameters['LocalToolPath'] = $LocalToolPath }
Invoke-Braver @braverParameters
