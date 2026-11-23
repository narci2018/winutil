# Round 13: Uninstall Applications tab.
# Installed programs are read from the three Uninstall registry hives and AppX
# packages; startup items come from Run/RunOnce, StartupApproved, the startup
# folders and scheduled tasks. Scanning and every system-changing operation run
# in a job worker. The interface thread only wires non-button events and renders
# rows; button clicks go through Invoke-WPFButtonAction's switch like every other
# static button in this project, so no control is double-wired.

function Format-WinUtilSize {
    param($Kilobytes)
    $kb = 0.0
    if ($null -ne $Kilobytes) { [void][double]::TryParse([string]$Kilobytes, [ref]$kb) }
    if ($kb -le 0) { return '' }
    if ($kb -ge 1048576) { return ('{0:N2} GB' -f ($kb / 1048576)) }
    if ($kb -ge 1024) { return ('{0:N1} MB' -f ($kb / 1024)) }
    return ('{0:N0} KB' -f $kb)
}

function Format-WinUtilInstallDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value -match '^\d{8}$') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($Value, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed.ToString('yyyy-MM-dd')
        }
    }
    return $Value
}

function ConvertTo-WinUtilExecutablePath {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $text = $CommandLine.Trim()
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) { return $text.Substring(1, $end - 1) }
    }
    $parts = $text -split '\s+', 2
    return $parts[0]
}

function Get-WinUtilFileCompany {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return '' }
    try {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($info.CompanyName) { return $info.CompanyName }
    } catch { }
    return ''
}

function Get-WinUtilInstalledPrograms {
    $result = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'Registry (64-bit)' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'Registry (32-bit)' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'Registry (User)' }
    )
    foreach ($root in $roots) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($p.DisplayName)) { continue }
                if ($p.ReleaseType -match 'Update|Hotfix|ServicePack') { continue }
                $uninstall = if ($p.QuietUninstallString) { $p.QuietUninstallString } else { $p.UninstallString }
                $hasMsi = ($p.PSObject.Properties.Name -contains 'WindowsInstaller') -or ($uninstall -match 'MsiExec')
                if (-not $uninstall -and -not $hasMsi) { continue }
                $location = if ($p.InstallLocation) { [string]$p.InstallLocation } else { '' }
                $displayIcon = if ($p.DisplayIcon) { [string]$p.DisplayIcon } else { '' }
                $category = 'Applications'
                if ($p.SystemComponent -eq 1) { $category = 'System Components' }
                $result.Add([pscustomobject]@{
                    Id              = $key.PSChildName
                    Name            = [string]$p.DisplayName
                    Version         = if ($p.DisplayVersion) { [string]$p.DisplayVersion } else { '' }
                    Publisher       = if ($p.Publisher) { [string]$p.Publisher } else { '' }
                    Company         = ''
                    Size            = Format-WinUtilSize $p.EstimatedSize
                    InstallDate     = Format-WinUtilInstallDate ([string]$p.InstallDate)
                    Location        = $location
                    DisplayIcon     = $displayIcon
                    UninstallString = if ($uninstall) { [string]$uninstall } else { '' }
                    RegistryPath    = $key.PSPath
                    Source          = $root.Source
                    Category        = $category
                    Hidden          = [bool]($p.SystemComponent -eq 1 -or $p.NoRemove -or $p.NoModify)
                    Kind            = 'Program'
                    Status          = ''
                    Command         = ''
                })
            } catch { }
        }
    }

    # Store apps: user AppX packages with a real name, exposed separately from the
    # registry programs. They are removed with Remove-AppxPackage on request.
    try {
        foreach ($pkg in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if (-not $pkg.Name -or $pkg.IsFramework -or $pkg.IsResourcePackage) { continue }
            $displayName = [string]$pkg.Name
            if ($displayName -match '^\{?[0-9a-fA-F-]{32,}\}?$' -or $displayName.Length -gt 80) {
                $displayName = if ($pkg.PackageFamilyName) { [string]$pkg.PackageFamilyName } else { [string]$pkg.PackageFullName }
            }
            $dateText = ''
            try { if ($pkg.InstallDate) { $dateText = ([datetime]$pkg.InstallDate).ToString('yyyy-MM-dd') } } catch { }
            $loc = if ($pkg.InstallLocation) { [string]$pkg.InstallLocation } else { '' }
            $result.Add([pscustomobject]@{
                Id              = [string]$pkg.PackageFullName
                Name            = $displayName
                Version         = if ($pkg.Version) { $pkg.Version.ToString() } else { '' }
                Publisher       = if ($pkg.Publisher) { [string]$pkg.Publisher } else { '' }
                Company         = ''
                Size            = ''
                InstallDate     = $dateText
                Location        = $loc
                DisplayIcon     = ''
                UninstallString = ''
                RegistryPath    = ''
                Source          = 'Store App'
                Category        = 'Store Apps'
                Hidden          = $false
                Kind            = 'StoreApp'
                PackageFullName = [string]$pkg.PackageFullName
                Status          = ''
                Command         = ''
            })
        }
    } catch { }

    return @($result | Sort-Object Name, Id)
}

function Get-WinUtilStartupApprovedState {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return 'Enabled' }
    # Windows stores Task Manager's disabled state as a leading 02/03 byte and
    # enabled state as leading 06 (or no value at all). Machine evidence: OneDrive
    # (02) is disabled while SecurityHealth (06) is enabled.
    if ($Bytes[0] -in @(2, 3)) { return 'Disabled' }
    return 'Enabled'
}

function Get-WinUtilStartupItems {
    $result = [System.Collections.Generic.List[object]]::new()

    $runPairs = @(
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Source = 'HKCU Run' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Source = 'HKLM Run' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\RunOnce'; Source = 'HKCU RunOnce' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\RunOnce'; Source = 'HKLM RunOnce' }
    )
    foreach ($pair in $runPairs) {
        $key = Get-Item -LiteralPath $pair.Path -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        $approved = Get-Item -LiteralPath $pair.Approved -ErrorAction SilentlyContinue
        foreach ($name in $key.GetValueNames()) {
            $command = [string]$key.GetValue($name)
            $bytes = if ($approved -and ($approved.GetValueNames() -contains $name)) { $approved.GetValue($name) } else { $null }
            $exe = ConvertTo-WinUtilExecutablePath $command
            $result.Add([pscustomobject]@{
                Id           = "$($pair.Source)|$name"
                Name         = $name
                Status       = Get-WinUtilStartupApprovedState $bytes
                Source       = $pair.Source
                Company      = Get-WinUtilFileCompany $exe
                Command      = $command
                Location     = $exe
                KeyPath      = $pair.Path
                ApprovedPath = $pair.Approved
                ValueName    = $name
                Kind         = 'RunKey'
                CanToggle    = $true
                Version      = ''
                Publisher    = ''
                Size         = ''
                InstallDate  = ''
                Category     = ''
                Hidden       = $false
                UninstallString = ''
                RegistryPath = $pair.Path
            })
        }
    }

    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            $result.Add([pscustomobject]@{
                Id           = "StartupFolder|$($file.FullName)"
                Name         = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                Status       = 'Enabled'
                Source       = if ($folder -like 'C:\ProgramData*') { 'Startup Folder (All Users)' } else { 'Startup Folder (Current User)' }
                Company      = ''
                Command      = $file.FullName
                Location     = $file.FullName
                KeyPath      = ''
                ApprovedPath = ''
                ValueName    = ''
                Kind         = 'StartupFolder'
                CanToggle    = $false
                Version      = ''
                Publisher    = ''
                Size         = ''
                InstallDate  = ''
                Category     = ''
                Hidden       = $false
                UninstallString = ''
                RegistryPath = ''
            })
        }
    }

    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            if (-not ($task.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon|Boot' })) { continue }
            $action = @($task.Actions | Where-Object { $_.Execute })[0]
            $cmd = if ($action) { ($action.Execute + ' ' + $action.Arguments).Trim() } else { '' }
            $result.Add([pscustomobject]@{
                Id           = "Task|$($task.TaskPath)$($task.TaskName)"
                Name         = [string]$task.TaskName
                Status       = if ($task.State -eq 'Disabled') { 'Disabled' } else { 'Enabled' }
                Source       = 'Windows Task'
                Company      = ''
                Command      = $cmd
                Location     = if ($action) { [string]$action.Execute } else { '' }
                KeyPath      = ''
                ApprovedPath = ''
                ValueName    = ''
                Kind         = 'ScheduledTask'
                CanToggle    = $false
                TaskPath     = [string]$task.TaskPath
                TaskName     = [string]$task.TaskName
                Version      = ''
                Publisher    = ''
                Size         = ''
                InstallDate  = ''
                Category     = ''
                Hidden       = $false
                UninstallString = ''
                RegistryPath = ''
            })
        }
    } catch { }

    return @($result | Sort-Object Name, Id)
}

function Get-WinUtilUninstallSelectedItem {
    $listName = if ($sync.UninstallView -eq 'Startup') { 'WPFUninstStartupList' } else { 'WPFUninstProgramList' }
    $list = $sync[$listName]
    if ($list) { return $list.SelectedItem }
    return $null
}

function Set-WinUtilUninstallDetails {
    param($Item)
    $empty = $sync['WPFUninstDetailEmpty']
    $grid = $sync['WPFUninstDetailGrid']
    if (-not $Item) {
        if ($empty) { $empty.Visibility = 'Visible' }
        if ($grid) { $grid.Visibility = 'Collapsed' }
        return
    }
    if ($empty) { $empty.Visibility = 'Collapsed' }
    if ($grid) { $grid.Visibility = 'Visible' }
    $map = @{
        'WPFUninstDName' = 'Name'; 'WPFUninstDVersion' = 'Version'; 'WPFUninstDPublisher' = 'Publisher'
        'WPFUninstDSize' = 'Size'; 'WPFUninstDDate' = 'InstallDate'; 'WPFUninstDStatus' = 'Status'
        'WPFUninstDSource' = 'Source'; 'WPFUninstDLocation' = 'Location'; 'WPFUninstDCommand' = 'Command'
    }
    foreach ($entry in $map.GetEnumerator()) {
        $tb = $sync[$entry.Key]
        if (-not $tb) { continue }
        $value = $Item.($entry.Value)
        if ($null -eq $value) { $value = '' }
        $tb.Text = [string]$value
    }
}

function ConvertTo-WinUtilUninstallDisplayRows {
    param([object[]]$Rows, [string]$View)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $clone = [pscustomobject]@{}
        foreach ($p in $row.PSObject.Properties) { $clone | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        foreach ($field in @('Status','Source','Category')) {
            $value = $clone.$field
            if ($value -is [string] -and $value) { $clone.$field = Get-WinUtilText $value }
        }
        $out.Add($clone)
    }
    return @($out)
}

function Update-WinUtilUninstallRows {
    param([string]$View, [object[]]$Rows)
    $listName = if ($View -eq 'Startup') { 'WPFUninstStartupList' } else { 'WPFUninstProgramList' }
    $list = $sync[$listName]
    if (-not $list) { return }
    $list.ItemsSource = @(ConvertTo-WinUtilUninstallDisplayRows -Rows $Rows -View $View)
    $rowCount = @($Rows).Count
    $count = $sync['WPFUninstCount']
    if ($count) {
        $label = if ($View -eq 'Startup') { (Get-WinUtilText 'items') } else { (Get-WinUtilText 'programs found') }
        $count.Text = "$rowCount $label"
    }
    $status = $sync['WPFUninstStatus']
    if ($status) {
        $status.Text = if ($View -eq 'Startup') {
            "$rowCount $(Get-WinUtilText 'startup items shown; Enable/Disable writes StartupApproved')"
        } else {
            "$rowCount $(Get-WinUtilText 'installed programs; Uninstall runs the program uninstaller after confirmation')"
        }
    }
    Set-WinUtilUninstallDetails $null
}

function Get-WinUtilUninstallFilterText {
    $tb = $sync['WPFUninstSearch']
    if ($tb) { return [string]$tb.Text }
    return ''
}

function Get-WinUtilUninstallCategory {
    foreach ($pair in @(
        @{ Name='WPFUninstCatApps'; Value='Applications' },
        @{ Name='WPFUninstCatSystem'; Value='System Components' },
        @{ Name='WPFUninstCatStore'; Value='Store Apps' },
        @{ Name='WPFUninstCatHidden'; Value='Hidden Components' }
    )) {
        $ctrl = $sync[$pair.Name]
        if ($ctrl -and $ctrl.IsChecked) { return $pair.Value }
    }
    return 'All'
}

function Update-WinUtilUninstallFilter {
    $all = @($sync.UninstallRows)
    $view = $sync.UninstallView
    if ($view -notin @('Programs','Startup')) { $view = 'Programs' }
    $search = Get-WinUtilUninstallFilterText
    if ($search) {
        $needle = [regex]::Escape($search)
        $all = @($all | Where-Object { "$($_.Name) $($_.Publisher) $($_.Command) $($_.Company)" -match $needle })
    }
    if ($view -ne 'Startup') {
        $cat = Get-WinUtilUninstallCategory
        if ($cat -eq 'Hidden Components') {
            $all = @($all | Where-Object { $_.Hidden })
        } elseif ($cat -ne 'All') {
            $all = @($all | Where-Object { $_.Category -eq $cat })
        }
    }
    Update-WinUtilUninstallRows -View $view -Rows $all
}

function Set-WinUtilUninstallView {
    param([string]$View)
    if ($View -notin @('Programs','Startup')) { return }
    $sync.UninstallView = $View
    $isStartup = $View -eq 'Startup'
    $show = if ($isStartup) { 'Collapsed' } else { 'Visible' }
    $hide = if ($isStartup) { 'Visible' } else { 'Collapsed' }
    foreach ($pair in @(
        @{ Name='WPFUninstProgramList'; Vis=$show },
        @{ Name='WPFUninstProgramActions'; Vis=$show },
        @{ Name='WPFUninstCategoryChips'; Vis=$show },
        @{ Name='WPFUninstStartupList'; Vis=$hide },
        @{ Name='WPFUninstStartupActions'; Vis=$hide }
    )) {
        $ctrl = $sync[$pair.Name]
        if ($ctrl) { $ctrl.Visibility = $pair.Vis }
    }
    $progToggle = $sync['WPFUninstViewPrograms']
    $startToggle = $sync['WPFUninstViewStartup']
    if ($progToggle) { $progToggle.IsChecked = -not $isStartup }
    if ($startToggle) { $startToggle.IsChecked = $isStartup }
    # Both datasets are collected by one scan, so switching views never rescans.
    $sync.UninstallRows = if ($isStartup) { @($sync.UninstallStartupRows) } else { @($sync.UninstallProgramRows) }
    Update-WinUtilUninstallFilter
}

function Start-WinUtilUninstallScan {
    param([string]$View = 'Programs', [switch]$QueueIfBusy)
    $loading = $sync['WPFUninstLoading']
    if ($loading) { $loading.Visibility = 'Visible'; $loading.Text = (Get-WinUtilText 'Scanning installed programs...') }
    $status = $sync['WPFUninstStatus']
    if ($status) { $status.Text = (Get-WinUtilText 'Scanning installed programs and startup items in the background...') }
    Start-WinUtilJob -Name "Uninstall Scan" -Description 'Scanning installed programs' -QueueIfBusy:$QueueIfBusy -Parameters @{
        ScanView = $View
    } -ScriptBlock {
        param($ScanView)
        Step-WinUtilJob -Status 'Reading installed programs and startup entries...' -Percent 10 -State 'Normal'
        $programs = @(Get-WinUtilInstalledPrograms)
        Step-WinUtilJob -Status 'Building the startup list...' -Percent 55
        $startup = @(Get-WinUtilStartupItems)
        Step-WinUtilJob -Status 'Publishing results...' -Percent 90
        Invoke-WPFUIThread -Async -Parameters @{ Programs = $programs; Startup = $startup; View = $ScanView } -ScriptBlock {
            param($Programs, $Startup, $View)
            $sync.UninstallProgramRows = @($Programs)
            $sync.UninstallStartupRows = @($Startup)
            $sync.UninstallDataLoaded = $true
            $loading = $sync['WPFUninstLoading']
            if ($loading) { $loading.Visibility = 'Collapsed' }
            $sync.UninstallRows = if ($View -eq 'Startup') { @($Startup) } else { @($Programs) }
            Update-WinUtilUninstallFilter
            Write-WinUtilLog -Level 'DEBUG' -Component 'UI' -Message ("uninstall scan probe: programs=$($Programs.Count) startup=$($Startup.Count) view=$View")
        }
        Step-WinUtilJob -Percent 100
    }
}

function Initialize-WinUtilUninstallTab {
    if ($sync.UninstallTabWired) { return }
    $sync.UninstallTabWired = $true
    $sync.UninstallView = 'Programs'
    $sync.UninstallDataLoaded = $false
    $sync.UninstallProgramRows = @()
    $sync.UninstallStartupRows = @()
    $sync.UninstallRows = @()

    # Buttons and ToggleButtons are already wired to Invoke-WPFButton by the
    # generic static-button pass; only non-button events are attached here.
    $sync['WPFUninstSearch'].Add_TextChanged({ Update-WinUtilUninstallFilter })
    $sync['WPFUninstProgramList'].Add_SelectionChanged({ Set-WinUtilUninstallDetails $args[0].SelectedItem })
    $sync['WPFUninstStartupList'].Add_SelectionChanged({ Set-WinUtilUninstallDetails $args[0].SelectedItem })

    Start-WinUtilUninstallScan -View 'Programs' -QueueIfBusy
}

function Invoke-WinUtilUninstallButton {
    param([string]$Button)
    switch ($Button) {
        'WPFUninstViewPrograms'  { Set-WinUtilUninstallView -View 'Programs'; return }
        'WPFUninstViewStartup'   { Set-WinUtilUninstallView -View 'Startup'; return }
        'WPFUninstRefresh'       { Start-WinUtilUninstallScan -View $sync.UninstallView -QueueIfBusy; return }
        { $_ -like 'WPFUninstCat*' } {
            foreach ($other in @('WPFUninstCatAll','WPFUninstCatApps','WPFUninstCatSystem','WPFUninstCatStore','WPFUninstCatHidden')) {
                if ($other -ne $Button -and $sync[$other]) { $sync[$other].IsChecked = $false }
            }
            $ctrl = $sync[$Button]
            if ($ctrl -and -not $ctrl.IsChecked) { $ctrl.IsChecked = $true }
            Update-WinUtilUninstallFilter
            return
        }
        'WPFUninstUninstall'            { Start-WinUtilUninstallAction -Action 'Uninstall'; return }
        'WPFUninstOpenLocation'         { Start-WinUtilUninstallAction -Action 'OpenProgramLocation'; return }
        'WPFUninstCopyCommand'          { Start-WinUtilUninstallAction -Action 'CopyCommand'; return }
        'WPFUninstOpenReg'              { Start-WinUtilUninstallAction -Action 'OpenRegistry'; return }
        'WPFUninstEnable'               { Start-WinUtilUninstallAction -Action 'EnableStartup'; return }
        'WPFUninstDisable'              { Start-WinUtilUninstallAction -Action 'DisableStartup'; return }
        'WPFUninstRemove'               { Start-WinUtilUninstallAction -Action 'RemoveStartup'; return }
        'WPFUninstAdd'                  { Start-WinUtilUninstallAction -Action 'AddStartup'; return }
        'WPFUninstStartupOpenLocation'  { Start-WinUtilUninstallAction -Action 'OpenStartupLocation'; return }
    }
}

function Start-WinUtilUninstallAction {
    param([string]$Action)
    $item = Get-WinUtilUninstallSelectedItem
    if (-not $item) {
        Show-WinUtilMessage -Message (Get-WinUtilText 'Select a program to see its details.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
        return
    }

    # UI-only actions stay on the interface thread: they must feel instant.
    if ($Action -in @('OpenProgramLocation','OpenStartupLocation','CopyCommand','OpenRegistry')) {
        try {
            $target = if ($Action -eq 'OpenRegistry') { [string]$item.RegistryPath } else { [string]$item.Location }
            if (-not $target) {
                Show-WinUtilMessage -Message (Get-WinUtilText 'No location is recorded for this item.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
                return
            }
            if ($Action -eq 'CopyCommand') {
                [Windows.Clipboard]::SetText([string]$item.UninstallString)
                $sync['WPFUninstStatus'].Text = 'Uninstall command copied to the clipboard.'
            } elseif ($Action -eq 'OpenRegistry') {
                # regedit has no command-line "select key" switch; copy the path and
                # open the editor so the user can paste it into the address bar.
                [Windows.Clipboard]::SetText($target)
                Start-Process -FilePath 'regedit.exe' -ErrorAction Stop
                $sync['WPFUninstStatus'].Text = "Registry key copied to the clipboard: $target"
            } else {
                $folder = if (Test-Path -LiteralPath $target -PathType Container) { $target } else { Split-Path -Path $target -Parent }
                if ($folder -and (Test-Path -LiteralPath $folder)) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList @($folder)
                    $sync['WPFUninstStatus'].Text = "Opened: $folder"
                } else {
                    Show-WinUtilMessage -Message (Get-WinUtilText 'No location is recorded for this item.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
                }
            }
        } catch {
            Show-WinUtilMessage -Message $_.Exception.Message -Title 'WinUtil' -Button 'OK' -Icon 'Warning'
        }
        return
    }

    if ($Action -eq 'AddStartup') {
        Show-WinUtilMessage -Message (Get-WinUtilText 'Adding a new startup item is intentionally disabled in this build.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
        return
    }

    $name = [string]$item.Name
    $confirm = switch ($Action) {
        'Uninstall'       { Show-WinUtilMessage -Message "Uninstall '$name'? This runs the program's own uninstaller." -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning' }
        'EnableStartup'   { Show-WinUtilMessage -Message "Enable the startup item '$name'?" -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning' }
        'DisableStartup'  { Show-WinUtilMessage -Message "Disable the startup item '$name'?" -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning' }
        'RemoveStartup'   { Show-WinUtilMessage -Message "Remove the startup entry '$name'? This deletes its Run value." -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning' }
    }
    if ("$confirm" -notin @('Yes','OK')) {
        $sync['WPFUninstStatus'].Text = 'Cancelled; nothing was changed.'
        return
    }

    $rowJson = $item | ConvertTo-Json -Depth 6 -Compress
    $viewName = $sync.UninstallView
    Start-WinUtilJob -Name "Uninstall $Action" -Description "$Action $name" -QueueIfBusy -Parameters @{
        Action = $Action
        RowJson = $rowJson
        ViewName = $viewName
    } -ScriptBlock {
        param($Action, $RowJson, $ViewName)
        $row = $RowJson | ConvertFrom-Json
        Step-WinUtilJob -Status "$Action $($row.Name)..." -Percent 10 -State 'Normal'
        $message = switch ($Action) {
            'Uninstall' {
                if ($row.Kind -eq 'StoreApp') {
                    Remove-AppxPackage -Package $row.PackageFullName -ErrorAction Stop
                    "Removed Store app $($row.Name)."
                } else {
                    $cmd = [string]$row.UninstallString
                    if (-not $cmd) { throw "No uninstall command is recorded for $($row.Name)." }
                    if ($cmd -match 'MsiExec') {
                        $msiArgs = ($cmd -replace '^"?MsiExec(\.exe)?"?\s*', '').Trim()
                        $p = Start-Process -FilePath "$env:WINDIR\System32\msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
                    } else {
                        $exe = ConvertTo-WinUtilExecutablePath $cmd
                        if (-not (Test-Path -LiteralPath $exe)) { throw "The uninstaller was not found: $exe" }
                        $argsLine = ''
                        if ($cmd.StartsWith('"')) {
                            $close = $cmd.IndexOf('"', 1)
                            if ($close -gt 1 -and $cmd.Length -gt ($close + 1)) { $argsLine = $cmd.Substring($close + 1).Trim() }
                        } elseif ($cmd.Length -gt $exe.Length) {
                            $argsLine = $cmd.Substring($exe.Length).Trim()
                        }
                        $startArgs = @{ FilePath = $exe; Wait = $true; PassThru = $true }
                        if ($argsLine) { $startArgs['ArgumentList'] = $argsLine }
                        $p = Start-Process @startArgs
                    }
                    if ($p.ExitCode -ne 0) { Write-WinUtilLog -Level 'WARN' -Component 'Uninstall' -Message "$($row.Name) uninstaller exit=$($p.ExitCode)" }
                    "Uninstaller finished for $($row.Name)."
                }
            }
            'EnableStartup'  { Set-WinUtilStartupEnabled -Row $row -Enabled $true; "Enabled $($row.Name)." }
            'DisableStartup' { Set-WinUtilStartupEnabled -Row $row -Enabled $false; "Disabled $($row.Name)." }
            'RemoveStartup'  {
                if (-not $row.KeyPath -or -not $row.ValueName) { throw 'Only Run/RunOnce startup values can be removed here.' }
                Remove-ItemProperty -LiteralPath $row.KeyPath -Name $row.ValueName -ErrorAction Stop
                $ap = $row.ApprovedPath
                if ($ap -and (Test-Path -LiteralPath $ap) -and ((Get-Item -LiteralPath $ap).GetValueNames() -contains $row.ValueName)) {
                    Remove-ItemProperty -LiteralPath $ap -Name $row.ValueName -ErrorAction SilentlyContinue
                }
                "Removed $($row.Name)."
            }
        }
        Step-WinUtilJob -Status $message -Percent 90
        Invoke-WPFUIThread -Async -Parameters @{ Msg = $message; View = $ViewName } -ScriptBlock {
            param($Msg, $View)
            $sync['WPFUninstStatus'].Text = $Msg
            Start-WinUtilUninstallScan -View $View -QueueIfBusy
        }
        Write-WinUtilLog -Component 'Uninstall' -Message $message
        Step-WinUtilJob -Percent 100
    }
}

function Set-WinUtilStartupEnabled {
    param($Row, [bool]$Enabled)
    if ($Row.Kind -eq 'ScheduledTask') {
        if ($Enabled) { Enable-ScheduledTask -TaskName $Row.TaskName -TaskPath $Row.TaskPath -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $Row.TaskName -TaskPath $Row.TaskPath -ErrorAction Stop | Out-Null }
        return
    }
    if (-not $Row.KeyPath -or -not $Row.ValueName) { throw 'This startup item cannot be toggled here.' }
    $approvedPath = [string]$Row.ApprovedPath
    if (-not (Test-Path -LiteralPath $approvedPath)) { New-Item -Path $approvedPath -Force | Out-Null }
    $key = Get-Item -LiteralPath $approvedPath
    $bytes = [byte[]]@(6,0,0,0,0,0,0,0,0,0,0,0)
    if ($Enabled) {
        $bytes[0] = 6
    } else {
        $existing = $key.GetValue($Row.ValueName)
        if ($existing -and $existing.Length -ge 12) { $bytes = [byte[]]$existing }
        $bytes[0] = 2
    }
    Set-ItemProperty -LiteralPath $approvedPath -Name $Row.ValueName -Value $bytes -Type Binary -ErrorAction Stop
}
