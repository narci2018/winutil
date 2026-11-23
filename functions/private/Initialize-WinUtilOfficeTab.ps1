<#
    .SYNOPSIS
        Initializes the Office Deployment tab (WPFTab9).

    .DESCRIPTION
        Phase 2 - Office deployment through the official Microsoft ODT (Office Deployment Tool).
        WinUtil generates a configuration.xml in the real ODT schema, downloads the ODT engine
        from the Microsoft C2R CDN, and runs `setup.exe /configure configuration.xml` inside a
        job worker so the interface never blocks. If the engine cannot be downloaded the user is
        asked for a local setup.exe on the interface thread, which also supports offline use.

        Phase 3 - Activation by downloading the official MAS (Microsoft Activation Scripts)
        scripts from the single authoritative massgravel repository and running them unattended.
        MAS is GPL-3.0 while WinUtil is MIT, so NO MAS code is copied into this repository; only
        the official scripts are downloaded at runtime, the same pattern WinUtil already uses for
        O&O ShutUp10. Look-alike repositories are never contacted.

        All long operations run in Start-WinUtilJob workers. Interface writes are marshalled back
        through Invoke-WPFUIThread, and the file picker is opened on the interface thread.
#>

# These constants live on $sync, NOT in $script: variables. The interface and every worker run in
# separate runspaces built from New-WinUtilSessionState, which transfers the shared $sync hashtable
# and the function definitions but NOT top-level $script: variables. A $script: constant assigned
# here would be $null in the UI runspace (empty config preview) and in job workers (broken download
# / activation). $sync is shared by reference across all runspaces, so the values survive. This is
# the same pattern the Uninstall and MAC tabs use.

# The one authoritative MAS source. Anything else is a look-alike and must never be executed.
$sync.MasRepoBase = 'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master'
$sync.MasSeparateDir = 'MAS/Separate-Files-Version'
$sync.MasActivatorsDir = 'Activators'

# MAS script file names (verified against the repository tree on 2026-11-23).
# Check_Activation_Status.cmd lives at the tree root; the four activators live under Activators/.
$sync.MasScriptFiles = @{
    HWID    = 'Activators/HWID_Activation.cmd'
    Ohook   = 'Activators/Ohook_Activation_AIO.cmd'
    KMS     = 'Activators/Online_KMS_Activation.cmd'
    TSforge = 'Activators/TSforge_Activation.cmd'
}

# Product -> ODT Product ID and matching Channel. A retail product must stay on its own channel.
# Office 2019/2016 are intentionally absent: their CDN builds are no longer reliably served.
$sync.OfficeProducts = @{
    'Microsoft 365' = @{ ProductId = 'O365ProPlusRetail'; Channel = 'Current' }
    'Office 2024'   = @{ ProductId = 'ProPlus2024Retail'; Channel = 'PerpetualVL2024' }
    'Office 2021'   = @{ ProductId = 'ProPlus2021Retail'; Channel = 'PerpetualVL2021' }
}

# Built-in ODT applications that map directly to an <ExcludeApp> ID. Visio/Project are separate
# products and are handled by adding their own <Product> element when selected.
$sync.OfficeBuiltInApps = @{
    WPFOfficeAppWord       = 'Word'
    WPFOfficeAppExcel      = 'Excel'
    WPFOfficeAppPowerPoint = 'PowerPoint'
    WPFOfficeAppAccess     = 'Access'
    WPFOfficeAppPublisher  = 'Publisher'
    WPFOfficeAppTeams      = 'Teams'
}

# The ODT engine itself. This is a stable, version-independent path (verified 200, PE/MZ,
# ~4.4 MB on 2026-11-23) and is the deployment engine, not the old ODTSetup.exe bootstrapper.
$sync.OdtEngineUrl = 'https://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/Office/Data/setup.exe'

function Initialize-WinUtilOfficeTab {
    if ($sync.OfficeTabWired) { return }
    $sync.OfficeConfigXml = ''
    $sync.OfficeOdtPath = ''

    # The wired flag is set only after a full successful pass. Initialize-WinUtilTabContent
    # resets its own InitializedTabs guard on failure so the tab can rebuild; if this inner
    # flag were set up front, a first-pass exception would leave the tab half-built forever
    # (every later call short-circuits here). Setting it at the end keeps the two guards honest.
    try {
    $sync['WPFOfficeProduct'].ItemsSource = @('Microsoft 365', 'Office 2024', 'Office 2021')
    $sync['WPFOfficeProduct'].SelectedIndex = 0

    $sync['WPFOfficeArch'].ItemsSource = @('x64', 'x86')
    $sync['WPFOfficeArch'].SelectedIndex = 0

    $sync['WPFOfficeLang'].ItemsSource = @('zh-CN', 'en-US', 'en-GB', 'ja-JP', 'ko-KR', 'de-DE', 'fr-FR', 'es-ES')
    $sync['WPFOfficeLang'].SelectedIndex = 0

    $sync['WPFOfficeWinMethod'].ItemsSource = @('HWID', 'Online KMS', 'TSforge')
    $sync['WPFOfficeWinMethod'].SelectedIndex = 0

    $sync['WPFOfficeOffMethod'].ItemsSource = @('Ohook', 'Online KMS')
    $sync['WPFOfficeOffMethod'].SelectedIndex = 0

    $sync['WPFOfficeAppWord'].IsChecked = $true
    $sync['WPFOfficeAppExcel'].IsChecked = $true
    $sync['WPFOfficeAppPowerPoint'].IsChecked = $true
    $sync['WPFOfficeAppAccess'].IsChecked = $false
    $sync['WPFOfficeAppPublisher'].IsChecked = $false
    $sync['WPFOfficeAppTeams'].IsChecked = $false
    $sync['WPFOfficeAppVisio'].IsChecked = $false
    $sync['WPFOfficeAppProject'].IsChecked = $false

    # Buttons route through Invoke-WPFButtonAction -> Invoke-WinUtilOfficeButton.

    Write-WinUtilLog -Level 'DEBUG' -Component 'Office' -Message 'office init: combos and checkboxes assigned'
    Invoke-WinUtilOfficeRefreshConfigPreview
    Write-WinUtilLog -Level 'DEBUG' -Component 'Office' -Message ("office init: config preview len=" + $sync.OfficeConfigXml.Length)
    Invoke-WinUtilOfficeRefreshActivationStatus
    $sync.OfficeTabWired = $true
    Write-WinUtilLog -Level 'DEBUG' -Component 'Office' -Message 'office init: complete'
    } catch {
        Write-WinUtilLog -Level 'ERROR' -Component 'Office' -Message ("office init FAILED: " + $_.Exception.Message)
        Write-WinUtilLog -Level 'DEBUG' -Component 'Office' -Message ("office init at: " + $_.InvocationInfo.PositionMessage)
        throw
    }
}

# Build a configuration.xml in the schema Microsoft ODT actually accepts:
# <Add OfficeClientEdition Channel><Product><Language/><ExcludeApp/></Product></Add>
# + <Display Level="None" AcceptEULA="TRUE"/>. Application checkboxes mean "install", so the
# unchecked built-in apps become <ExcludeApp> entries (ODT has no <Applications><Application>).
function New-WinUtilOfficeConfigurationXml {
    param(
        [string]$Product = 'Microsoft 365',
        [string]$Arch = 'x64',
        [string]$Lang = 'zh-CN',
        [string[]]$BuiltInApps = @('Word', 'Excel', 'PowerPoint'),
        [switch]$Visio,
        [switch]$Project
    )

    $meta = $sync.OfficeProducts[$Product]
    if (-not $meta) { $meta = $sync.OfficeProducts['Microsoft 365'] }
    $edition = if ($Arch -eq 'x86') { '32' } else { '64' }

    $lines = @('<Configuration>')
    $lines += "  <Add OfficeClientEdition=`"$edition`" Channel=`"$($meta.Channel)`">"
    $lines += "    <Product ID=`"$($meta.ProductId)`">"
    $lines += "      <Language ID=`"$Lang`" />"
    foreach ($app in $sync.OfficeBuiltInApps.Values) {
        if ($BuiltInApps -notcontains $app) {
            $lines += "      <ExcludeApp ID=`"$app`" />"
        }
    }
    $lines += '    </Product>'
    if ($Visio) {
        $lines += '    <Product ID="VisioProRetail">'
        $lines += "      <Language ID=`"$Lang`" />"
        $lines += '    </Product>'
    }
    if ($Project) {
        $lines += '    <Product ID="ProjectProRetail">'
        $lines += "      <Language ID=`"$Lang`" />"
        $lines += '    </Product>'
    }
    $lines += '  </Add>'
    $lines += '  <Display Level="None" AcceptEULA="TRUE" />'
    $lines += '</Configuration>'
    return ($lines -join "`r`n")
}

function Get-WinUtilOfficeUiSelection {
    $builtIn = @()
    foreach ($key in $sync.OfficeBuiltInApps.Keys) {
        $cb = $sync[$key]
        if ($cb -and $cb.IsChecked) { $builtIn += $sync.OfficeBuiltInApps[$key] }
    }
    $visio = [bool]($sync['WPFOfficeAppVisio'] -and $sync['WPFOfficeAppVisio'].IsChecked)
    $project = [bool]($sync['WPFOfficeAppProject'] -and $sync['WPFOfficeAppProject'].IsChecked)
    $product = if ($sync['WPFOfficeProduct'].SelectedItem) { [string]$sync['WPFOfficeProduct'].SelectedItem } else { 'Microsoft 365' }
    $arch = if ($sync['WPFOfficeArch'].SelectedItem) { [string]$sync['WPFOfficeArch'].SelectedItem } else { 'x64' }
    $lang = if ($sync['WPFOfficeLang'].SelectedItem) { [string]$sync['WPFOfficeLang'].SelectedItem } else { 'zh-CN' }
    return @{
        Product = $product; Arch = $arch; Lang = $lang
        BuiltInApps = $builtIn; Visio = $visio; Project = $project
    }
}

function Invoke-WinUtilOfficeRefreshConfigPreview {
    $sel = Get-WinUtilOfficeUiSelection
    $xml = New-WinUtilOfficeConfigurationXml -Product $sel.Product -Arch $sel.Arch -Lang $sel.Lang `
        -BuiltInApps $sel.BuiltInApps -Visio:$sel.Visio -Project:$sel.Project
    $sync.OfficeConfigXml = $xml
    $preview = $sync['WPFOfficeConfigPreview']
    if ($preview) { $preview.Text = $xml }
}

# Download the ODT engine to the temp folder, verifying it is a PE binary. Returns the path or
# $null. Runs on any thread; the interactive fallback is deliberately handled by the caller on
# the interface thread so OpenFileDialog is never created off the dispatcher.
function Get-WinUtilOfficeOdtEngine {
    if ($sync.OfficeOdtPath -and (Test-Path $sync.OfficeOdtPath)) { return $sync.OfficeOdtPath }

    $workDir = Join-Path $env:TEMP 'winutil-odt'
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
    $dest = Join-Path $workDir 'setup.exe'

    Step-WinUtilJob -Status 'Downloading the Office Deployment Tool...' -Percent 20
    try {
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        Invoke-WebRequest -Uri $sync.OdtEngineUrl -UseBasicParsing -Headers @{ 'User-Agent' = $ua } -OutFile $dest -TimeoutSec 180
        $item = Get-Item $dest -ErrorAction Stop
        $fs = [System.IO.File]::OpenRead($dest)
        try {
            $magic = New-Object byte[] 2
            [void]$fs.Read($magic, 0, 2)
        } finally { $fs.Dispose() }
        if ($item.Length -gt 1000000 -and $magic[0] -eq 0x4D -and $magic[1] -eq 0x5A) {
            $sync.OfficeOdtPath = $dest
            Write-WinUtilLog -Level 'INFO' -Component 'Office' -Message "ODT engine downloaded: $dest ($($item.Length) bytes)"
            return $dest
        }
        Write-WinUtilLog -Level 'WARN' -Component 'Office' -Message "ODT engine failed PE validation: $dest ($($item.Length) bytes)"
    } catch {
        Write-WinUtilLog -Level 'WARN' -Component 'Office' -Message "ODT engine download failed: $($_.Exception.Message)"
    }
    return $null
}

# Open the file picker on the interface thread and wait for the result.
function Get-WinUtilOfficeLocalEnginePath {
    return Invoke-WPFUIThread -PassThru -ScriptBlock {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Office Deployment Tool (setup.exe)|setup.exe|All files (*.*)|*.*'
        $dlg.Title = (Get-WinUtilText 'Select the ODT setup.exe file')
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and (Test-Path $dlg.FileName)) {
            return $dlg.FileName
        }
        return $null
    }
}

# Run a process asynchronously so a chatty MAS/OUT stream cannot fill the pipe and deadlock the
# worker. stdin is closed and a timeout kills a script that waits on input or a trailing pause.
function Invoke-WinUtilOfficeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 600
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Close()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return @{ TimedOut = $true; Output = ''; ExitCode = -1 }
        }
        [void]$stdoutTask.Wait($TimeoutSeconds * 1000)
        [void]$stderrTask.Wait($TimeoutSeconds * 1000)
        $out = $stdoutTask.Result
        $err = $stderrTask.Result
        return @{ TimedOut = $false; Output = "$out`n$err"; ExitCode = $proc.ExitCode }
    } finally {
        $proc.Dispose()
    }
}

# Phase 2 entry point. Called from the interface thread by the button router.
function Start-WinUtilOfficeDeploy {
    $sel = Get-WinUtilOfficeUiSelection
    $xml = New-WinUtilOfficeConfigurationXml -Product $sel.Product -Arch $sel.Arch -Lang $sel.Lang `
        -BuiltInApps $sel.BuiltInApps -Visio:$sel.Visio -Project:$sel.Project
    $xmlPath = Join-Path $env:TEMP 'winutil-odt-configuration.xml'
    Set-Content -Path $xmlPath -Value $xml -Encoding UTF8

    Start-WinUtilJob -Name 'Office Deployment' -Description 'Deploying Office' -ScriptBlock {
        param($XmlPath)
        try {
            $odt = Get-WinUtilOfficeOdtEngine
            if (-not $odt) {
                Step-WinUtilJob -Status 'The Office Deployment Tool could not be downloaded.' -Percent 30
                $chosen = Get-WinUtilOfficeLocalEnginePath
                if (-not $chosen) {
                    Step-WinUtilJob -Status 'Office deployment cancelled: no ODT engine selected.' -Percent 100 -State 'Error'
                    return
                }
                $odt = $chosen
                $sync.OfficeOdtPath = $chosen
            }

            Step-WinUtilJob -Status 'Running the Office deployment...' -Percent 45
            $quotedXml = '"' + $XmlPath.Replace('"', '\"') + '"'
            $result = Invoke-WinUtilOfficeProcess -FilePath $odt -Arguments "/configure $quotedXml" `
                -WorkingDirectory (Split-Path $odt -Parent) -TimeoutSeconds 3600

            if ($result.TimedOut) {
                Step-WinUtilJob -Status 'Office deployment timed out.' -Percent 100 -State 'Error'
                return
            }
            if ($result.ExitCode -ne 0) {
                Write-WinUtilLog -Level 'ERROR' -Component 'Office' -Message "ODT exited $($result.ExitCode): $($result.Output)"
                Step-WinUtilJob -Status 'Office deployment failed. See the session log for details.' -Percent 100 -State 'Error'
                return
            }

            Step-WinUtilJob -Status 'Office deployment finished.' -Percent 100
            Invoke-WPFUIThread -Async -ScriptBlock {
                $status = $sync['WPFOfficeStatus']
                if ($status) { $status.Text = Get-WinUtilText 'Office deployment finished. Restart Office apps to pick up the installation.' }
            }
        } catch {
            Write-WinUtilLog -Level 'ERROR' -Component 'Office' -Message "Office deployment error: $($_.Exception.Message)"
            Step-WinUtilJob -Status 'Office deployment failed. See the session log for details.' -Percent 100 -State 'Error'
        }
    } -Parameters @{ XmlPath = $xmlPath }
}

# Read the language-independent activation state from SoftwareLicensingProduct. slmgr/ospp.vbs
# output is localized and cannot be matched with English regexes, so licensing is queried by the
# well-known ApplicationId GUIDs instead. Returns two display strings.
function Get-WinUtilOfficeLicenseStrings {
    $winAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    $offAppId = '0ff1ce15-a989-479d-af46-f275c6370663'
    $winText = Get-WinUtilText 'Windows: Status unknown'
    $offText = Get-WinUtilText 'Office: Status unknown'
    try {
        $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
            Where-Object { $_.PartialProductKey -and $_.ApplicationId })
        $win = @($products | Where-Object { $_.ApplicationId -eq $winAppId } | Select-Object -First 1)
        $off = @($products | Where-Object { $_.ApplicationId -eq $offAppId } | Select-Object -First 1)
        if ($win.Count -gt 0) {
            $winText = if ($win[0].LicenseStatus -eq 1) { Get-WinUtilText 'Windows: Activated' } else { Get-WinUtilText 'Windows: Not activated' }
        } else {
            $winText = Get-WinUtilText 'Windows: Not activated'
        }
        if ($off.Count -gt 0) {
            $offText = if ($off[0].LicenseStatus -eq 1) { Get-WinUtilText 'Office: Activated' } else { Get-WinUtilText 'Office: Not activated' }
        } else {
            $offText = Get-WinUtilText 'Office: Not installed'
        }
    } catch {
        $winText = Get-WinUtilText 'Windows: Status unavailable'
        $offText = Get-WinUtilText 'Office: Status unavailable'
    }
    return @{ Win = $winText; Off = $offText }
}

# Refresh activation status off the UI thread (the CIM query can take a second or more).
function Invoke-WinUtilOfficeRefreshActivationStatus {
    Invoke-WPFRunspace -ScriptBlock {
        $status = Get-WinUtilOfficeLicenseStrings
        Invoke-WPFUIThread -Async -Parameters @{ Win = $status.Win; Off = $status.Off } -ScriptBlock {
            param($Win, $Off)
            $w = $sync['WPFOfficeWinStatus']
            $o = $sync['WPFOfficeOffStatus']
            if ($w) { $w.Text = $Win }
            if ($o) { $o.Text = $Off }
        }
    }
}

# Download the official MAS scripts into a working folder. Returns the folder path or $null.
function Get-WinUtilMasWorkDir {
    $workDir = Join-Path $env:TEMP 'winutil-mas'
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

    $relPaths = @($sync.MasScriptFiles.Values) + @('Check_Activation_Status.cmd')
    foreach ($rel in $relPaths) {
        $dest = Join-Path $workDir (Split-Path $rel -Leaf)
        if (Test-Path $dest) { continue }
        $url = "$($sync.MasRepoBase)/$($sync.MasSeparateDir)/$rel"
        try {
            Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -OutFile $dest -TimeoutSec 90
            if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1000) {
                throw "downloaded script is missing or too small: $dest"
            }
        } catch {
            Write-WinUtilLog -Level 'ERROR' -Component 'Activation' -Message "MAS script download failed ($rel): $($_.Exception.Message)"
            return $null
        }
    }
    return $workDir
}

# Phase 3 entry point. The confirmation runs on the interface thread via Show-WinUtilMessage.
function Start-WinUtilActivation {
    param(
        [ValidateSet('Windows', 'Office')][string]$Target,
        [string]$Method
    )

    $confirmMsg = if ($Target -eq 'Windows') {
        Get-WinUtilText 'Activation modifies the Windows license state on this machine. It is intended for systems you own. Continue?'
    } else {
        Get-WinUtilText 'Activation modifies the Office license state on this machine. It is intended for systems you own. Continue?'
    }
    $confirm = Show-WinUtilMessage -Message $confirmMsg -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning'
    if ("$confirm" -ne 'Yes') { return }

    $jobDesc = if ($Target -eq 'Windows') { 'Activating Windows' } else { 'Activating Office' }
    Start-WinUtilJob -Name "Activation ($Target)" -Description $jobDesc -ScriptBlock {
        param($Target, $Method)
        Step-WinUtilJob -Status 'Downloading the activation scripts...' -Percent 15
        $workDir = Get-WinUtilMasWorkDir
        if (-not $workDir) {
            Step-WinUtilJob -Status 'The activation scripts could not be downloaded.' -Percent 100 -State 'Error'
            return
        }

        $scriptRel = $null
        $switch = $null
        $status = ''
        if ($Target -eq 'Windows') {
            switch ($Method) {
                'HWID'        { $scriptRel = $sync.MasScriptFiles.HWID; $switch = '/HWID'; $status = 'Activating Windows via HWID...' }
                'Online KMS'  { $scriptRel = $sync.MasScriptFiles.KMS; $switch = '/K-Windows'; $status = 'Activating Windows via KMS...' }
                'TSforge'     { $scriptRel = $sync.MasScriptFiles.TSforge; $switch = '/Z-Windows'; $status = 'Activating Windows via TSforge...' }
            }
        } else {
            if ($Method -eq 'Ohook') {
                $scriptRel = $sync.MasScriptFiles.Ohook; $switch = '/Ohook'; $status = 'Activating Office via Ohook...'
            } else {
                $scriptRel = $sync.MasScriptFiles.KMS; $switch = '/K-Office'; $status = 'Activating Office via KMS...'
            }
        }
        if (-not $scriptRel) {
            Step-WinUtilJob -Status 'The selected activation method is not available.' -Percent 100 -State 'Error'
            return
        }

        Step-WinUtilJob -Status $status -Percent 40
        $scriptPath = Join-Path $workDir (Split-Path $scriptRel -Leaf)
        $args = '/c "' + $scriptPath + '" ' + $switch
        $result = Invoke-WinUtilOfficeProcess -FilePath 'cmd.exe' -Arguments $args -WorkingDirectory $workDir -TimeoutSeconds 900

        Write-WinUtilLog -Level 'INFO' -Component 'Activation' -Message "MAS $switch finished (exit $($result.ExitCode), timeout=$($result.TimedOut)): $($result.Output)"
        Step-WinUtilJob -Status 'Activation process finished.' -Percent 85
        Invoke-WPFUIThread -Async -ScriptBlock { Invoke-WinUtilOfficeRefreshActivationStatus }
        if ($result.TimedOut) {
            Step-WinUtilJob -Status 'Activation timed out. Check the session log.' -Percent 100 -State 'Error'
        } else {
            Step-WinUtilJob -Status 'Activation finished.' -Percent 100
        }
    } -Parameters @{ Target = $Target; Method = $Method }
}

function Start-WinUtilUnactivate {
    $confirm = Show-WinUtilMessage -Message (Get-WinUtilText 'This removes the activation from the selected product and returns it to its prior licensing state. Continue?') -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning'
    if ("$confirm" -ne 'Yes') { return }

    Start-WinUtilJob -Name 'Uninstall Activation' -Description 'Removing activation' -ScriptBlock {
        param($WinMethod, $OffMethod)
        Step-WinUtilJob -Status 'Downloading the activation scripts...' -Percent 15
        $workDir = Get-WinUtilMasWorkDir
        if (-not $workDir) {
            Step-WinUtilJob -Status 'The activation scripts could not be downloaded.' -Percent 100 -State 'Error'
            return
        }

        $ran = $false
        $jobs = @()
        if ($WinMethod -eq 'Online KMS') {
            $jobs += @{ Script = $sync.MasScriptFiles.KMS; Switch = '/K-Uninstall' }
        }
        if ($OffMethod -eq 'Ohook') {
            $jobs += @{ Script = $sync.MasScriptFiles.Ohook; Switch = '/Ohook-Uninstall' }
        }
        # HWID has no uninstall switch (it writes a hardware-bound digital license); TSforge
        # likewise has no /Z-Uninstall. Those states are intentionally left unchanged.

        foreach ($job in $jobs) {
            $scriptPath = Join-Path $workDir (Split-Path $job.Script -Leaf)
            $args = '/c "' + $scriptPath + '" ' + $job.Switch
            $result = Invoke-WinUtilOfficeProcess -FilePath 'cmd.exe' -Arguments $args -WorkingDirectory $workDir -TimeoutSeconds 600
            Write-WinUtilLog -Level 'INFO' -Component 'Activation' -Message "MAS $($job.Switch) finished (exit $($result.ExitCode), timeout=$($result.TimedOut))"
            $ran = $true
        }

        Step-WinUtilJob -Status 'Activation removal finished.' -Percent 85
        Invoke-WPFUIThread -Async -ScriptBlock { Invoke-WinUtilOfficeRefreshActivationStatus }
        if (-not $ran) {
            Step-WinUtilJob -Status 'No removable activation was selected (HWID and TSforge have no uninstall switch).' -Percent 100
        } else {
            Step-WinUtilJob -Status 'Activation removal finished.' -Percent 100
        }
    } -Parameters @{
        WinMethod = if ($sync['WPFOfficeWinMethod'].SelectedItem) { [string]$sync['WPFOfficeWinMethod'].SelectedItem } else { 'HWID' }
        OffMethod = if ($sync['WPFOfficeOffMethod'].SelectedItem) { [string]$sync['WPFOfficeOffMethod'].SelectedItem } else { 'Ohook' }
    }
}

function Invoke-WinUtilOfficeButton {
    param([string]$Button)
    switch ($Button) {
        'WPFOfficeGenConfig' { Invoke-WinUtilOfficeRefreshConfigPreview; return }
        'WPFOfficeDeploy'    { Start-WinUtilOfficeDeploy; return }
        'WPFActivateWin'     {
            $method = if ($sync['WPFOfficeWinMethod'].SelectedItem) { [string]$sync['WPFOfficeWinMethod'].SelectedItem } else { 'HWID' }
            Start-WinUtilActivation -Target Windows -Method $method
            return
        }
        'WPFActivateOff'     {
            $method = if ($sync['WPFOfficeOffMethod'].SelectedItem) { [string]$sync['WPFOfficeOffMethod'].SelectedItem } else { 'Ohook' }
            Start-WinUtilActivation -Target Office -Method $method
            return
        }
        'WPFUnactivate'      { Start-WinUtilUnactivate; return }
    }
}
