<#
    .SYNOPSIS
        Hidden, opt-in gateway to the external, destructive bin456789/reinstall tool.

    .DESCRIPTION
        bin456789/reinstall (https://github.com/bin456789/reinstall) is a real, actively
        maintained GPL-3.0 reinstaller. It does NOT replace Windows inside the running session:
        it installs Cygwin, stages an Alpine netboot kernel/initrd, writes a one-shot BCD/EFI boot
        entry, and after a reboot wipes every partition on the main disk before running Windows
        setup unattended. It requires at least two reboots, erases all data, changes the boot
        configuration, bypasses Win11 hardware checks and may trigger Defender warnings.

        WinUtil is MIT licensed. GPL-3.0 and MIT are incompatible, so NO script, answer file,
        batch fragment or other code from that repository is copied into this project. This file
        only downloads the upstream entry points and drives them as external child processes;
        it never embeds their implementation. Whether such an external invocation makes WinUtil a
        derivative work is a legal question, which is why the entry point sits behind the
        Windows Reinstall navigation tab, requires an explicit acknowledgement checkbox and two
        separate YesNo confirmations, and is never invoked by any automated verification step.

        Supply-chain pin: the upstream repository has no release/tag and its scripts default to
        fetching further scripts from the moving "main" branch at run time. Both entry scripts
        are therefore downloaded from one fixed commit and every confhome / confhome_cn line is
        rewritten from "main" to that commit before anything can be launched. If the pin cannot
        be applied, Test-WinUtilReinstallPrepared fails and Start refuses to run.

        The install source is optional. If the operator supplies an ISO direct link or local path
        it is forwarded with --iso. When it is left blank no --iso argument is passed, so the
        upstream tool falls back to its own automatic installer download, matching its one-command
        usage (bash reinstall.sh windows --image-name "..."). Note that upstream auto-discovery
        path is outside WinUtil's control.

        Defining these functions downloads and executes nothing. Nothing runs until the operator
        explicitly clicks Start on the Windows Reinstall navigation tab.
#>

# Constants live on $sync, NOT in top-level script-scoped variables. The interface and every job
# run in separate runspaces built from New-WinUtilSessionState, which transfers the shared $sync
# hashtable and the function definitions but NOT top-level script-scoped variables. This is the
# same pattern the Office, Uninstall and MAC tabs use; a script-scoped constant here would be null
# in those runspaces.
$sync.ReinstallCommit = 'd9ede3db41ddbf0a026a7109f2d1a469375eaaad'
$sync.ReinstallRepoBase = 'https://raw.githubusercontent.com/bin456789/reinstall'
$sync.ReinstallWorkDir = Join-Path $env:TEMP 'winutil-reinstall'
$sync.ReinstallBatName = 'reinstall.bat'
$sync.ReinstallShName = 'reinstall.sh'

function Get-WinUtilReinstallWorkDir {
    <#
        .SYNOPSIS
            Returns the working directory that holds the pinned external entry scripts.
    #>
    if ($null -eq $sync) { return $null }
    return $sync.ReinstallWorkDir
}

function Write-WinUtilReinstallLog {
    <#
        .SYNOPSIS
            Writes one line to the WinUtil session log and to the hidden tab status TextBlock.

        .DESCRIPTION
            The status control belongs to the interface thread, so the append is posted rather
            than waited on. With no window it degrades to the session log alone, keeping job
            bodies and headless verification free of "is there a UI" checks. The script block is
            self-contained because Invoke-WPFUIThread marshals its body as text.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    Write-WinUtilLog -Level $Level -Component "Reinstall" -Message $Message

    Invoke-WPFUIThread -Async -Parameters @{
        LogLine = "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
    } -ScriptBlock {
        param($LogLine)

        $box = $sync["WPFReinstallStatus"]
        if ($null -eq $box) { return }

        if ([string]::IsNullOrEmpty($box.Text)) {
            $box.Text = $LogLine
        } else {
            $box.Text = $box.Text + "`n" + $LogLine
        }
    }
}

function Test-WinUtilReinstallPrepared {
    <#
        .SYNOPSIS
            Returns true only when both entry scripts exist AND their confhome lines are pinned.

        .DESCRIPTION
            This is the only gate that permits Invoke-WinUtilReinstallStart to launch anything.
            A partial download, an unchanged "main" branch line, or a missing file all fail closed.
    #>
    $workDir = Get-WinUtilReinstallWorkDir
    if ([string]::IsNullOrWhiteSpace($workDir)) { return $false }

    foreach ($name in @($sync.ReinstallBatName, $sync.ReinstallShName)) {
        $path = Join-Path $workDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

        $content = [System.IO.File]::ReadAllText($path)
        $confLines = @($content -split "`r?`n" | Where-Object {
            $normalized = $_ -replace '^\s*@?\s*', ''
            $normalized = $normalized -replace '^(set\s+)', ''
            $normalized = $normalized -replace '^"', ''
            $normalized -match '^(?:confhome_cn|confhome)\s*='
        })
        if ($confLines.Count -eq 0) { return $false }

        foreach ($line in $confLines) {
            if ($line -notlike "*$($sync.ReinstallCommit)*") { return $false }
            # No unpinned branch reference may survive on a confhome line.
            if ($line -match '/main([/"''\s]|$)') { return $false }
        }
    }

    return $true
}

function Invoke-WinUtilReinstallPrepare {
    <#
        .SYNOPSIS
            Downloads and pins the two upstream entry scripts. Never executes them.
    #>
    $workDir = Get-WinUtilReinstallWorkDir
    if ([string]::IsNullOrWhiteSpace($workDir)) {
        Write-WinUtilReinstallLog -Message 'Prepare refused: the reinstall working directory is not configured.' -Level ERROR
        return $false
    }

    try {
        if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $workDir -Force
        }
    } catch {
        Write-WinUtilReinstallLog -Message "Prepare failed: cannot create $workDir - $($_.Exception.Message)" -Level ERROR
        return $false
    }

    foreach ($name in @($sync.ReinstallBatName, $sync.ReinstallShName)) {
        $url = "$($sync.ReinstallRepoBase)/$($sync.ReinstallCommit)/$name"
        $destination = Join-Path $workDir $name

        try {
            Write-WinUtilReinstallLog -Message "Downloading pinned $name from commit $($sync.ReinstallCommit)."
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
            $content = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($content)) { throw 'Downloaded file is empty.' }

            # Only confhome / confhome_cn assignment lines are rewritten; every other line of the
            # upstream script is stored byte-for-byte. The optional "set"/quote handling covers the
            # batch-file form as well as the shell form without widening the match.
            $pinnedCount = 0
            $updatedLines = @(foreach ($line in ($content -split "`r?`n")) {
                $normalized = $line -replace '^\s*@?\s*', ''
                $normalized = $normalized -replace '^(set\s+)', ''
                $normalized = $normalized -replace '^"', ''
                if ($normalized -match '^(?:confhome_cn|confhome)\s*=' -and $normalized -match 'main') {
                    $pinnedCount++
                    $line -replace 'main', $sync.ReinstallCommit
                } else {
                    $line
                }
            })
            if ($pinnedCount -eq 0) {
                throw "No confhome / confhome_cn line containing 'main' was found in $name; refusing to store an unpinned script."
            }

            # No BOM: these are upstream shell/batch files, and a BOM would break their interpreters.
            [System.IO.File]::WriteAllText($destination, ($updatedLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
            Write-WinUtilReinstallLog -Message "Stored pinned $name ($pinnedCount confhome line(s) rewritten). No script was executed."
        } catch {
            Write-WinUtilReinstallLog -Message "Prepare failed for $name - $($_.Exception.Message)" -Level ERROR
            return $false
        }
    }

    if (-not (Test-WinUtilReinstallPrepared)) {
        Write-WinUtilReinstallLog -Message 'Prepare incomplete: the downloaded scripts did not pass the pin verification.' -Level ERROR
        return $false
    }

    Write-WinUtilReinstallLog -Message 'Prepare complete. Read the warnings before starting a destructive reinstall.'
    return $true
}

function Get-WinUtilReinstallArguments {
    <#
        .SYNOPSIS
            Builds the cmd.exe argument string for the external reinstall tool.

        .DESCRIPTION
            Shared by Invoke-WinUtilReinstallStart and the on-screen command preview, so the
            command the operator can copy is byte-for-byte the one WinUtil would run. The install
            source is optional: when it is blank no --iso is passed and the upstream tool falls
            back to its own official-installer download, matching its one-command usage.
    #>
    param(
        [string]$IsoUrl = '',
        [string]$ImageName = ''
    )

    $workDir = Get-WinUtilReinstallWorkDir
    $batPath = Join-Path $workDir $sync.ReinstallBatName
    $arguments = '/c "' + $batPath + '" windows'
    if (-not [string]::IsNullOrWhiteSpace($IsoUrl)) {
        $arguments += ' --iso "' + $IsoUrl + '"'
    }
    if (-not [string]::IsNullOrWhiteSpace($ImageName)) {
        $arguments += ' --image-name "' + $ImageName + '"'
    }
    return $arguments
}

function Update-WinUtilReinstallCommandPreview {
    <#
        .SYNOPSIS
            Refreshes the read-only command preview from the current source and edition.
    #>
    $preview = if ($sync.ContainsKey('WPFReinstallCommandPreview')) { $sync['WPFReinstallCommandPreview'] } else { $null }
    if ($null -eq $preview) { return }

    $isoBox = if ($sync.ContainsKey('WPFReinstallIsoUrl')) { $sync['WPFReinstallIsoUrl'] } else { $null }
    $nameBox = if ($sync.ContainsKey('WPFReinstallImageName')) { $sync['WPFReinstallImageName'] } else { $null }
    $isoUrl = if ($null -ne $isoBox) { [string]$isoBox.Text } else { '' }
    $imageName = if ($null -ne $nameBox) { [string]$nameBox.Text } else { '' }

    $arguments = Get-WinUtilReinstallArguments -IsoUrl $isoUrl -ImageName $imageName
    $preview.Text = 'cmd.exe ' + $arguments
}

function Copy-WinUtilReinstallCommand {
    <#
        .SYNOPSIS
            Copies the command preview to the clipboard. Runs nothing.
    #>
    $preview = if ($sync.ContainsKey('WPFReinstallCommandPreview')) { $sync['WPFReinstallCommandPreview'] } else { $null }
    if ($null -eq $preview -or [string]::IsNullOrWhiteSpace($preview.Text)) {
        Write-WinUtilReinstallLog -Message 'Nothing to copy: the command preview is empty.' -Level WARN
        return $false
    }
    try {
        [System.Windows.Clipboard]::SetText($preview.Text)
        Write-WinUtilReinstallLog -Message 'Reinstall command copied to the clipboard. Nothing was executed.'
        return $true
    } catch {
        Write-WinUtilReinstallLog -Message "Copy failed - $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Invoke-WinUtilReinstallStart {
    <#
        .SYNOPSIS
            Starts the pinned external reinstall tool after every gate has been satisfied.

        .DESCRIPTION
            Gate order is deliberate and must not be reordered:
              1. explicit acknowledgement checkbox
              2. verified pinned scripts (Prepare already run)
              3. two independent YesNo warnings covering disk erase, boot changes, Cygwin and reboots
            The install source is optional. A user-supplied ISO direct link or local path is
            forwarded with --iso; when left blank no --iso argument is passed and the upstream
            tool automatically downloads the official installer, matching its one-command usage.
            Failure or "No" at any gate returns without launching a process.
    #>
    $ack = $sync["WPFReinstallAckCheck"]
    if ($null -eq $ack -or -not $ack.IsChecked) {
        Write-WinUtilReinstallLog -Message 'Start refused: acknowledge the destructive reinstall checkbox first.' -Level WARN
        return $false
    }

    if (-not (Test-WinUtilReinstallPrepared)) {
        Write-WinUtilReinstallLog -Message 'Start refused: pinned scripts are missing or unverified. Run Prepare first.' -Level WARN
        return $false
    }

    $isoBox = $sync["WPFReinstallIsoUrl"]
    $nameBox = $sync["WPFReinstallImageName"]
    $isoUrl = if ($null -ne $isoBox) { [string]$isoBox.Text } else { '' }
    $imageName = if ($null -ne $nameBox) { [string]$nameBox.Text } else { '' }

    if ($isoUrl -match '["\r\n]' -or $imageName -match '["\r\n]') {
        Write-WinUtilReinstallLog -Message 'Start refused: the source link and image name must not contain quotes or line breaks.' -Level WARN
        return $false
    }

    $warningOne = Get-WinUtilText 'WARNING: this ERASES ALL DATA ON THE MAIN DISK, including every partition. It cannot be undone. Continue?'
    $answerOne = Show-WinUtilMessage -Message $warningOne -Title (Get-WinUtilText 'Destructive reinstall - confirmation 1 of 2') -Button YesNo -Icon Warning
    if ("$answerOne" -ne 'Yes') {
        Write-WinUtilReinstallLog -Message 'Start cancelled: the disk-erase confirmation was not accepted.' -Level WARN
        return $false
    }

    $warningTwo = Get-WinUtilText 'WARNING: the external tool installs Cygwin, rewrites the boot configuration, enters Alpine/WinPE and needs AT LEAST TWO REBOOTS before Windows is reinstalled. Continue?'
    $answerTwo = Show-WinUtilMessage -Message $warningTwo -Title (Get-WinUtilText 'Destructive reinstall - confirmation 2 of 2') -Button YesNo -Icon Warning
    if ("$answerTwo" -ne 'Yes') {
        Write-WinUtilReinstallLog -Message 'Start cancelled: the reboot and boot-configuration confirmation was not accepted.' -Level WARN
        return $false
    }

    $workDir = Get-WinUtilReinstallWorkDir
    $arguments = Get-WinUtilReinstallArguments -IsoUrl $isoUrl -ImageName $imageName

    Write-WinUtilReinstallLog -Message "Starting the pinned external reinstall tool from commit $($sync.ReinstallCommit). This is an external GPL tool, not a WinUtil implementation."

    # Same asynchronous pattern as the Office external process helper: a chatty or paused script
    # would otherwise fill the pipe and deadlock, and stdin must be closed so no prompt can hang.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $workDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true

    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        try {
            $process.StandardInput.Close()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(1800 * 1000)) {
                try { $process.Kill() } catch { }
                Write-WinUtilReinstallLog -Message 'External reinstall tool timed out after 1800 seconds and was terminated.' -Level ERROR
                return $false
            }
            [void]$stdoutTask.Wait(30000)
            [void]$stderrTask.Wait(30000)
            $exitCode = $process.ExitCode
            $output = "$($stdoutTask.Result)`n$($stderrTask.Result)"
        } finally {
            $process.Dispose()
        }
    } catch {
        Write-WinUtilReinstallLog -Message "External reinstall tool could not be started - $($_.Exception.Message)" -Level ERROR
        return $false
    }

    Write-WinUtilReinstallLog -Message "External reinstall tool exited with code $exitCode."
    $outputText = ($output -replace '[\r\n]+', ' | ')
    if ($outputText.Length -gt 1200) { $outputText = $outputText.Substring($outputText.Length - 1200) }
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-WinUtilReinstallLog -Message "External reinstall tool output: $outputText"
    }
    return $true
}

function Invoke-WinUtilReinstallCancel {
    <#
        .SYNOPSIS
            Runs the upstream reset command to drop a pending reinstall before the reboot.
    #>
    $confirmation = Get-WinUtilText 'Cancel the pending reinstall? This only works before the reboot; once it starts, the disk wipe can no longer be cancelled.'
    $answer = Show-WinUtilMessage -Message $confirmation -Title (Get-WinUtilText 'Cancel reinstall') -Button YesNo -Icon Warning
    if ("$answer" -ne 'Yes') {
        Write-WinUtilReinstallLog -Message 'Cancel aborted: no reset command was run.' -Level WARN
        return $false
    }

    $workDir = Get-WinUtilReinstallWorkDir
    $shPath = Join-Path $workDir $sync.ReinstallShName
    if (-not (Test-Path -LiteralPath $shPath -PathType Leaf)) {
        Write-WinUtilReinstallLog -Message 'Cancel failed: the pinned reinstall.sh is missing. Run Prepare first.' -Level ERROR
        return $false
    }

    $cygwinBash = Join-Path $env:SystemDrive 'cygwin\bin\bash.exe'
    $bashExe = if (Test-Path -LiteralPath $cygwinBash -PathType Leaf) { $cygwinBash } else { 'bash' }
    Write-WinUtilReinstallLog -Message "Running the external reinstall reset command with $bashExe."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bashExe
    $psi.Arguments = '"' + $shPath + '" reset'
    $psi.WorkingDirectory = $workDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true

    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        try {
            $process.StandardInput.Close()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(300 * 1000)) {
                try { $process.Kill() } catch { }
                Write-WinUtilReinstallLog -Message 'External reinstall reset timed out after 300 seconds and was terminated.' -Level ERROR
                return $false
            }
            [void]$stdoutTask.Wait(30000)
            [void]$stderrTask.Wait(30000)
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }
    } catch {
        Write-WinUtilReinstallLog -Message "External reinstall reset could not be started - $($_.Exception.Message)" -Level ERROR
        return $false
    }

    Write-WinUtilReinstallLog -Message "External reinstall reset exited with code $exitCode."
    return $true
}
