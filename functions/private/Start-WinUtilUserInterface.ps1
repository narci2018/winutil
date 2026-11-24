function Start-WinUtilUserInterface {
    <#
        .SYNOPSIS
            Builds the WinUtil window, wires its event handlers and runs it to completion

        .DESCRIPTION
            This is the whole interface. It runs on the dedicated STA interface runspace that
            main.ps1 starts, so the thread that owns the window does nothing but paint and
            dispatch: every long operation goes to the worker pool through Start-WinUtilJob.

            The call blocks until the window is closed, and the interface runspace is the only
            place that is allowed to touch controls directly.
    #>

    $buildClock = [System.Diagnostics.Stopwatch]::StartNew()

    Measure-WinUtilStep -Scope "UI" -Name "load WPF assemblies" -ScriptBlock {
        [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
    }

    # ModernWpf 缺失时剥离 Fluent 字典引用,回退自带皮肤(仅观感降级,不阻断启动)
    $xamlSource = $inputXML
    if (-not $sync.ModernWpfLoaded) {
        $xamlSource = $xamlSource -replace '(?m)^\s*<modern:ThemeResources[^>]*/>\s*\r?\n', ''
        $xamlSource = $xamlSource -replace '(?m)^\s*<modernControls:XamlControlsResources/>\s*\r?\n', ''
    }
    [xml]$XAML = $xamlSource

    # Read the XAML file
    $readerOperationSuccessful = $false # There's more cases of failure then success.
    $readerFailure = $null
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    try {
        Measure-WinUtilStep -Scope "UI" -Name "parse XAML" -ScriptBlock {
            $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
        }
        $readerOperationSuccessful = $true
    } catch [System.Management.Automation.MethodInvocationException] {
        $readerFailure = $_
        Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
        Write-Host $error[0].Exception.Message -ForegroundColor Red

        If ($error[0].Exception.Message -like "*button*") {
            write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
        }
    } catch {
        $readerFailure = $_
        Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
    }

    if (-NOT ($readerOperationSuccessful)) {
        Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
        Write-Host "Quitting WinUtil..." -ForegroundColor Red
        Write-WinUtilLog -Level "ERROR" -Component "UI" -Message "Failed to parse the XAML content. WinUtil cannot start."
        throw [System.InvalidOperationException]::new("Failed to parse the XAML content. WinUtil cannot start.", $readerFailure.Exception)
    }

    # Setup the Window to follow listen for windows Theme Change events and update the winutil theme
    # throttle logic needed, because windows seems to send more than one theme change event per change
    $themeState = @{ LastChange = [datetime]::MinValue }
    $debounceInterval = [timespan]::FromSeconds(2)
    $sync.Form.Add_Loaded({
        $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
        $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
        $hwndSource.AddHook({
            param (
                [System.IntPtr]$hwnd,
                [int]$msg,
                [System.IntPtr]$wParam,
                [System.IntPtr]$lParam,
                [ref]$handled
            )
            $null = $hwnd, $wParam, $lParam
            if ($msg -eq 0x001A) { Request-WinUtilWindowInsets }
            # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
            if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
                $currentTime = [datetime]::Now
                if ($currentTime - $themeState.LastChange -gt $debounceInterval) {
                    Invoke-WinutilThemeChange -theme "Auto"
                    $themeState.LastChange = $currentTime
                    # [ref] out-parameter: assigning to $handled would only replace the local
                    $handled.Value = $true
                }
            }
            return 0
        })
    })

    # Restore persisted preferences (theme/language) or follow the system on first run
    if (-not $sync.ContainsKey('PreferencesLoaded')) {
        $sync.PreferencesLoaded = $true
        try {
            $prefPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'winutil\preferences.json'
            if (Test-Path $prefPath) {
                $pref = Get-Content $prefPath -Raw | ConvertFrom-Json
                # Skin v2 (Modern redesign) migration: preferences written before the redesign
                # carry no skinVersion marker, so a stored theme (e.g. "Cyberpunk") would
                # silently hide the new default skin. Language is honored; the theme is forced
                # to Modern exactly once and the marker persisted, after which the user's own
                # theme choice wins.
                if (-not $pref.PSObject.Properties['skinVersion'] -or $pref.skinVersion -ne 2) {
                    $sync.preferences.theme = "Modern"
                    $pref | Add-Member -NotePropertyName skinVersion -NotePropertyValue 2 -Force
                    $pref | Add-Member -NotePropertyName theme -NotePropertyValue "Modern" -Force
                    $pref | ConvertTo-Json -Depth 3 | Set-Content $prefPath -Encoding UTF8
                    Write-WinUtilLog -Component "UI" -Message "Skin v2 migration: theme reset to Modern."
                }
                elseif ($pref.theme -and $sync.configs['themes'].PSObject.Properties.Name -contains $pref.theme) {
                    $sync.preferences.theme = $pref.theme
                }
                if ($pref.lang) { $sync.preferences.lang = $pref.lang }
            }
        } catch {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not load preferences: $($_.Exception.Message)"
        }
        # First run: follow the Windows display language when it is Chinese
        if (-not $sync.preferences.lang) {
            try {
                $sysLang = [System.Globalization.CultureInfo]::CurrentUICulture.Name
                if ($sysLang -like 'zh*') { $sync.preferences.lang = 'zh-CN' }
            } catch { }
        }
    }

    Measure-WinUtilStep -Scope "UI" -Name "apply theme" -ScriptBlock {
        Invoke-WinutilThemeChange -theme $sync.preferences.theme
    }

    # Apply the UI language before any tab content is built
    if ($sync.preferences.lang -and $sync.preferences.lang -ne 'en') {
        Set-WinUtilLanguage -lang $sync.preferences.lang
    }

    # Tab content is built when its tab is activated: the default tab just before the window is
    # shown, the others when they are opened or warmed up.
    $sync.InitializedTabs = @{}

    #===========================================================================
    # Store Form Objects In PowerShell
    #===========================================================================

    Measure-WinUtilStep -Scope "UI" -Name "map named controls" -ScriptBlock {
        $xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}
    }

    $sync.WindowInsetsPending = $false
    $sync.WindowInsetsUpdate = [action]{
        $sync.WindowInsetsPending = $false
        if (Test-WinUtilUIAlive) { Update-WinUtilWindowInsets }
    }
    $sync.Form.Add_Loaded({ Request-WinUtilWindowInsets })

    # Apply modern window chrome (Mica backdrop, rounded corners, dark frame) once the
    # window handle exists - the startup theme call runs before the handle, so chrome
    # would otherwise be skipped on first launch until the user switches themes.
    $sync.Form.Add_Loaded({
        $resolved = if ($sync.ContainsKey('LastResolvedTheme') -and $sync.LastResolvedTheme) { $sync.LastResolvedTheme } else { "Modern" }
        Enable-WinUtilModernChrome -DarkMode:($resolved -in @("Dark", "Cyberpunk", "Modern"))
    })
    $sync.Form.Add_StateChanged({ Request-WinUtilWindowInsets })
    $sync.Form.Add_SizeChanged({ Request-WinUtilWindowInsets })
    $sync.Form.Add_LocationChanged({ Request-WinUtilWindowInsets })
    $sync.Form.Add_DpiChanged({ Request-WinUtilWindowInsets })

    # Built here so it carries this runspace's session state: posted work then runs as ordinary
    # interface code, not a much slower cross-runspace nested pipeline. Invoke-WPFUIThread is the
    # caller-facing side.
    $sync.UIDispatchDelegate = [System.Func[object, object]]{
        param($Work)

        try {
            $body = [scriptblock]::Create($Work.Body)
            $parameters = $Work.Parameters
            if ($parameters -and $parameters.Count -gt 0) {
                & $body @parameters
            } else {
                & $body
            }
        } catch {
            if ($Work.PropagateErrors) {
                throw
            }
            # Fire-and-forget work has no waiting caller to report its failure.
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Interface work"
        }
    }

    Measure-WinUtilStep -Scope "UI" -Name "wire static button clicks" -ScriptBlock {
        # CheckBox and RadioButton also derive from ButtonBase, so the exact type name is what
        # decides, not -is
        $clickableTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@("Button", "ToggleButton"), [StringComparer]::OrdinalIgnoreCase)
        $alreadyWired = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.Buttons), [StringComparer]::OrdinalIgnoreCase)

        $clickHandler = {
            [System.Object]$Sender = $args[0]
            Invoke-WPFButton $Sender.name
        }

        foreach ($entry in @($sync.GetEnumerator())) {
            $control = $entry.Value
            if ($null -eq $control -or -not $clickableTypes.Contains($control.GetType().Name)) {
                continue
            }
            if (-not $alreadyWired.Add([string]$entry.Key)) {
                continue
            }

            $control.Add_Click($clickHandler)
            $sync.Buttons.Add($entry.Key) | Out-Null
        }
    }

    #===========================================================================
    # Setup and Show the Form
    #===========================================================================

    # Progress bar in taskbaritem > Set-WinUtilProgressbar
    $sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
    Set-WinUtilTaskbaritem -state "None"

    # Wired before the window is shown, so work queued during startup already knows to stand
    # aside for anything the user does
    Register-WinUtilInputWatch

    # Set the titlebar
    $sync["Form"].title = $sync["Form"].title + " " + $sync.version
    # Set the commands that will run when the form is closed
    $sync["Form"].Add_Closing({
        param($eventSender, $closingArgs)
        $null = $eventSender

        # The pool cannot be torn down under work that is still running: the runspace error that
        # follows is unhandled and ends the process
        if (($sync.ActiveJob -or $sync.JobQueue.Count -gt 0) -and -not $sync.ForceClose) {
            $closingArgs.Cancel = $true
            $runningJob = if ($sync.ActiveJob) { $sync.ActiveJob } else { "Queued operations" }
            Invoke-WinUtilCloseRequest -RunningJob $runningJob -QueuedCount $sync.JobQueue.Count
            return
        }

        # Past the prompt the window is closing for good, and nothing queued may start after it
        $null = Clear-WinUtilJobQueue

        # Work that is meant to outlive the window needs the pool it is running on. main.ps1
        # waits for it and shuts the pool down once it is done.
        if ($sync.FinishInConsole) {
            Write-WinUtilLog -Component "UI" -Message "Window closing, leaving $($sync.ActiveJob) to finish in the console."
            return
        }

        # main.ps1 owns pool shutdown after the window has finished closing. Doing it from this
        # dispatcher callback can deadlock with a worker that is in its UI-thread cleanup block.
        Write-WinUtilLog -Component "UI" -Message "Window closing; the main thread will shut down the worker pool."
    })

    # Attach the event handler to the Click event
    $sync.SearchBarClearButton.Add_Click({
        $sync.SearchBar.Text = ""
        $sync.SearchBarClearButton.Visibility = "Collapsed"

        # Focus the search bar after clearing the text
        $sync.SearchBar.Focus()
        $sync.SearchBar.SelectAll()
    })

    # add some shortcuts for people that don't like clicking
    function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

    $commonKeyEvents = {
        if ($sync.ActiveJob) {
            return
        }

        # Handle key presses of single keys
        switch ($_.Key) {
            "Escape" { $sync.SearchBar.Text = "" }
        }
        # Handle Alt key combinations for navigation
        if ($_.KeyboardDevice.Modifiers -eq "Alt") {
            $keyEventArgs = $_
            switch ($_.SystemKey) {
                "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
                "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
                "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
                "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
                "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
            }
        }
        # Handle Ctrl key combinations for specific actions
        if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
            $keyEventArgs = $_
            switch ($_.Key) {
                "F" { $sync.SearchBar.Focus() } # Focus on the search bar
                "Q" { $this.Close() } # Close the application
            }
        }
        $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
        if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
            $keyEventArgs = $_
            switch ($_.Key) {
                { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
                { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
            }
        }
    }
    $sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
    $sync["Form"].Add_PreviewMouseWheel({
        if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
    })

    $sync["Form"].Add_MouseLeftButtonDown({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
        $sync["Form"].DragMove()
    })

    $sync["Form"].Add_MouseDoubleClick({
        if ($_.OriginalSource.Name -eq "NavDockPanel" -or
            $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
                if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                    [Windows.SystemCommands]::MaximizeWindow($sync.Form)
                }
                else{
                    [Windows.SystemCommands]::RestoreWindow($sync.Form)
                }
        }
    })

    $sync["Form"].Add_Deactivated({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    })

    $sync["Form"].Add_ContentRendered({
        # Load the Windows Forms assembly
        Add-Type -AssemblyName System.Windows.Forms
        $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
        # Check if the primary screen is found
        if ($primaryScreen) {
            # Extract screen width and height for the primary monitor
            $screenWidth = $primaryScreen.Bounds.Width
            $screenHeight = $primaryScreen.Bounds.Height
            $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

            # Compare with the primary monitor size
            if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
                $sync.Form.Left = 0
                $sync.Form.Top = 0
                $sync.Form.Width = $screenWidth
                $sync.Form.Height = $screenHeight
            }
        }

        if ($PARAM_OFFLINE) {
            # Show offline banner
            $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

            # Disable the install tab
            $sync.WPFTab1BT.IsEnabled = $false
            $sync.WPFTab1BT.Opacity = 0.5
            $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications."
            if ($sync.ContainsKey('NavView') -and $sync.NavView) {
                $navInstall = @($sync.NavView.MenuItems) | Where-Object { $_.Tag -eq 'WPFTab1' } | Select-Object -First 1
                if ($navInstall) { $navInstall.IsEnabled = $false }
            }

            # The install action buttons are generated with the Install tab, so
            # Initialize-WinUtilInstallTabControls disables them when that tab is built

            # Show offline indicator
            Write-Host "Offline mode detected - Install tab disabled." -ForegroundColor Yellow

            # Optionally switch to a different tab if install tab was going to be default
            Invoke-WPFTab "WPFTab2BT" -Yield  # Switch to Tweaks tab instead
        }
        else {
            # Online - ensure install tab is enabled
            $sync.WPFTab1BT.IsEnabled = $true
            $sync.WPFTab1BT.Opacity = 1.0
            $sync.WPFTab1BT.ToolTip = $null
            if ($sync.ContainsKey('NavView') -and $sync.NavView) {
                $navInstall = @($sync.NavView.MenuItems) | Where-Object { $_.Tag -eq 'WPFTab1' } | Select-Object -First 1
                if ($navInstall) { $navInstall.IsEnabled = $true }
            }
            Invoke-WPFTab "WPFTab1BT" -Yield  # Default to install tab
        }

        $sync["Form"].Focus()
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
            Set-WinUtilTaskbaritem -overlay "logo"
        }) | Out-Null
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Start-WinUtilTabWarmup }) | Out-Null
    })

    # The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
    # This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

    $searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
    $searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $searchBarTimer.IsEnabled = $false

    $searchBarTimer.add_Tick({
        $searchBarTimer.Stop()
        switch ($sync.currentTab) {
            "Install" {
                Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $sync.SelectedAppCategories.ToArray()
            }
            "Tweaks" {
                Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
            }
            "AppX" {
                Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
            }
        }
    })
    $sync["SearchBar"].Add_TextChanged({
        if ($sync.SearchBar.Text -ne "") {
            $sync.SearchBarClearButton.Visibility = "Visible"
            $sync.SearchBarIcon.Visibility = "Collapsed"
        } else {
            $sync.SearchBarClearButton.Visibility = "Collapsed"
            $sync.SearchBarIcon.Visibility = "Visible"
        }

        if ($searchBarTimer.IsEnabled) {
            $searchBarTimer.Stop()
        }
        $searchBarTimer.Start()
    })

    # Category filter chips. The chip carries its category in Tag, so one handler covers all of them.
    $sync.AppCategoryChips = @(
        @{ Name = "WPFSearchChipAll";             Category = "" }
        @{ Name = "WPFSearchChipBrowsers";        Category = "Browsers" }
        @{ Name = "WPFSearchChipCommunications";  Category = "Communications" }
        @{ Name = "WPFSearchChipDevelopment";     Category = "Development" }
        @{ Name = "WPFSearchChipDocument";        Category = "Document" }
        @{ Name = "WPFSearchChipGames";           Category = "Games" }
        @{ Name = "WPFSearchChipMicrosoftTools";  Category = "Microsoft Tools" }
        @{ Name = "WPFSearchChipMultimediaTools"; Category = "Multimedia Tools" }
        @{ Name = "WPFSearchChipProTools";        Category = "Pro Tools" }
        @{ Name = "WPFSearchChipSelfhostedTools"; Category = "Selfhosted Tools" }
        @{ Name = "WPFSearchChipUtilities";       Category = "Utilities" }
    )
    $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()

    foreach ($appCategoryChip in $sync.AppCategoryChips) {
        $sync[$appCategoryChip.Name].Tag = $appCategoryChip.Category
        $sync[$appCategoryChip.Name].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
    }

    $sync["Form"].Add_Loaded({
        param($e)
        $null = $e
        $sync.Form.MinWidth = "1150"
        $sync["Form"].MaxWidth = [Double]::PositiveInfinity
        $sync["Form"].MaxHeight = [Double]::PositiveInfinity
    })

    Measure-WinUtilStep -Scope "UI" -Name "build nav logo" -ScriptBlock {
        $NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
        $NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
    }

    $sync["Form"].Add_Activated({
        Set-WinUtilTaskbaritem -overlay "logo"
    })

    $sync["ThemeButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
    })
    $sync["AutoThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Auto"
    })
    $sync["DarkThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Dark"
    })
    $sync["LightThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Light"
    })
    $sync["CyberpunkThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Cyberpunk"
    })
    $sync["ModernThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Modern"
    })
    $sync["ClassicLightThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "ClassicLight"
    })

    # Language switching
    $sync["LangEnMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Set-WinUtilLanguage -lang 'en'
        if ($sync.UninstallDataLoaded) { Update-WinUtilUninstallFilter }
        if ($sync.MacDataLoaded) { Update-WinUtilMacRows -Rows $sync.MacAdapters }
    })
    $sync["LangZhMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Set-WinUtilLanguage -lang 'zh-CN'
        if ($sync.UninstallDataLoaded) { Update-WinUtilUninstallFilter }
        if ($sync.MacDataLoaded) { Update-WinUtilMacRows -Rows $sync.MacAdapters }
    })

    # A popup that closes on outside clicks also closes on the click that would toggle it, which
    # would then reopen it, so a click straight after a close is that same click
    $sync.JobQueuePopupClosedAt = [DateTime]::MinValue
    $sync["JobQueuePopup"].Add_Closed({ $sync.JobQueuePopupClosedAt = [DateTime]::UtcNow })
    $sync["JobQueuePopup"].Add_Opened({ Update-WinUtilJobQueueUI })
    $sync["JobQueueButton"].Add_Click({
        if (([DateTime]::UtcNow - $sync.JobQueuePopupClosedAt).TotalMilliseconds -lt 300) { return }
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Hide"; "JobQueue" = "Show" }
    })

    $sync["SettingsButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
    })
    $sync["ImportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFImpex -type "import"
    })
    $sync["ExportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFImpex -type "export"
    })
    $sync["ExportEnvironmentReportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFExportEnvironmentReport
    })
    $sync["AboutMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

        $authorInfo = @"
$(Get-WinUtilText 'Author')   : <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
$(Get-WinUtilText 'UI')       : <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
$(Get-WinUtilText 'Runspace') : <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>
GitHub   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
$(Get-WinUtilText 'Version')  : <a href="https://github.com/ChrisTitusTech/winutil/releases/tag/$($sync.version)">$($sync.version)</a>
"@
        Show-CustomDialog -Title (Get-WinUtilText "About") -Message $authorInfo
    })
    $sync["DocumentationMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Start-Process "https://winutil.christitus.com/"
    })
    $sync["SponsorMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

        $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">$(Get-WinUtilText 'Current sponsors for ChrisTitusTech:')</a>
"@
        $authorInfo += "`n"
        try {
            $sponsors = Invoke-WinUtilSponsors
            foreach ($sponsor in $sponsors) {
                $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
            }
        } catch {
            $authorInfo += "$(Get-WinUtilText 'An error occurred while fetching or processing the sponsors:') $_`n"
        }
        Show-CustomDialog -Title (Get-WinUtilText "Sponsors") -Message $authorInfo -EnableScroll $true
    })

    # Font Scaling Event Handlers
    $sync["FontScalingButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
    })

    $sync["FontScalingSlider"].Add_ValueChanged({
        param($slider)
        $percentage = [math]::Round($slider.Value * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    })

    $sync["FontScalingResetButton"].Add_Click({
        $sync.FontScalingSlider.Value = 1.0
        $sync.FontScalingValue.Text = "100%"
    })

    $sync["FontScalingApplyButton"].Add_Click({
        $scaleFactor = $sync.FontScalingSlider.Value
        Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
        Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
    })

    # Win11ISO Tab button handlers
    $sync["WPFWin11ISOBrowseButton"].Add_Click({
        Invoke-WinUtilISOBrowse
    })

    $sync["WPFWin11ISODownloadLink"].Add_Click({
        Start-Process "https://www.microsoft.com/software-download/windows11"
    })

    $sync["WPFWin11ISOMountButton"].Add_Click({
        Invoke-WinUtilISOMountAndVerify
    })

    $sync["WPFWin11ISOModifyButton"].Add_Click({
        Invoke-WinUtilISOModify
    })

    $sync["WPFWin11ISOChooseISOButton"].Add_Click({
        $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
        Invoke-WinUtilISOExport
    })

    $sync["WPFWin11ISOChooseUSBButton"].Add_Click({
        $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
        Invoke-WinUtilISORefreshUSBDrives
    })

    $sync["WPFWin11ISORefreshUSBButton"].Add_Click({
        Invoke-WinUtilISORefreshUSBDrives
    })

    $sync["WPFWin11ISOWriteUSBButton"].Add_Click({
        Invoke-WinUtilISOWriteUSB
    })

    $sync["WPFWin11ISOCleanResetButton"].Add_Click({
        Invoke-WinUtilISOCleanAndReset
    })

    $sync["WPFWin11ISOBackButton"].Add_Click({
        $sync["WPFWin11ISOSelectSection"].IsSelected = $true
    })

    $sync["WPFWin11ISOForwardButton"].Add_Click({
        $sync["WPFWin11ISOModifySection"].IsSelected = $true
    })

    # Reinstall (hidden high-risk external entry) button handlers
    $sync["WPFReinstallPrepareButton"].Add_Click({
        Invoke-WinUtilReinstallPrepare
    })

    $sync["WPFReinstallStartButton"].Add_Click({
        Invoke-WinUtilReinstallStart
    })

    $sync["WPFReinstallCancelButton"].Add_Click({
        Invoke-WinUtilReinstallCancel
    })

    # Command preview: the same builder Start uses, so the copyable command is exactly what
    # would run. Copy only touches the clipboard and never launches anything.
    $sync["WPFReinstallCopyButton"].Add_Click({
        Copy-WinUtilReinstallCommand
    })

    $sync["WPFReinstallIsoUrl"].Add_TextChanged({
        Update-WinUtilReinstallCommandPreview
    })

    $sync["WPFReinstallImageName"].Add_TextChanged({
        Update-WinUtilReinstallCommandPreview
    })

    Update-WinUtilReinstallCommandPreview

    $buildClock.Stop()
    Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "Interface built in $($buildClock.ElapsedMilliseconds) ms, showing the window."
    Write-WinUtilTimingSummary -Scope "UI" -TotalMilliseconds $buildClock.ElapsedMilliseconds

    # Input priority runs behind everything already queued, so this fires at the first moment
    # the window could actually service a click
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [action]{
        $sinceStart = [int]((Get-Date) - $sync.StartedAt).TotalMilliseconds
        Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "timing: interface ready for input $sinceStart ms after start."
    }) | Out-Null

    # NavigationView is the WinUI-style nav shell for the tabs. Switching still goes through
    # Invoke-WPFTab (single source of truth); the handler only forwards user clicks. NavSyncing
    # is consumed here so the sync back in Invoke-WPFTab does not re-enter.
    #
    # Ninth-round regression: real mouse clicks did nothing. Two independent holes:
    #   1) A stale NavSyncing flag (set by a programmatic switch whose SelectedItem was
    #      already the same object) swallowed the first real SelectionChanged event.
    #   2) ModernWpf's internal click path can leave SelectedItem without a Tag.
    # Fix: guard has a timestamp and auto-expires; Tag is resolved from several
    # sources; each NavigationViewItem also gets a direct PreviewMouseLeftButtonUp
    # handler as a click-level fallback (offline probe 16: RaiseEvent -> WPFTab2/3/4).
    $navView = $sync["Form"].FindName("WPFNavView")
    if ($navView) {
        $sync["NavView"] = $navView
        $navView.add_SelectionChanged({
            param($sender, $e)
            # Expire a stale guard (e.g. programmatic switch to the already-selected item).
            $stamp = $sync.NavSyncingAt
            if ($sync.NavSyncing -and (-not $stamp -or ((Get-Date) - $stamp).TotalSeconds -gt 2)) {
                $sync.Remove('NavSyncing'); $sync.Remove('NavSyncingAt')
            }
            if ($sync.NavSyncing) {
                $sync.Remove('NavSyncing'); $sync.Remove('NavSyncingAt')
                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "nav selection: ignored programmatic sync"
                return
            }
            $candidates = @()
            if ($e) {
                if ($e.PSObject.Properties.Name -contains 'SelectedItem' -and $e.SelectedItem) { $candidates += $e.SelectedItem }
                if ($e.PSObject.Properties.Name -contains 'SelectedItemContainer' -and $e.SelectedItemContainer) { $candidates += $e.SelectedItemContainer }
            }
            if ($sender -and $sender.SelectedItem) { $candidates += $sender.SelectedItem }
            $navTag = $null
            foreach ($c in $candidates) {
                if ($c.PSObject.Properties.Name -contains 'Tag' -and $c.Tag -match '^WPFTab\d+$') { $navTag = $c.Tag.ToString(); break }
            }
            $before = $sync.currentTab
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("nav selection: tag=[$navTag] before=[$before] selType=$(if($e -and $e.SelectedItem){$e.SelectedItem.GetType().Name}else{'null'})")
            if ($navTag -match '^WPFTab\d+$') { Invoke-WPFTab $navTag }
        })

        # Ninth-round follow-up: item-level handlers never fired on real clicks, so the
        # event must be intercepted before it reaches the item (or the items never get
        # hit at all). Two layers of defense + diagnostics:
        #  a) NavView-level PreviewMouseLeftButtonUp - tunneling ALWAYS passes through
        #     the NavigationView before any child; resolve Tag from OriginalSource
        #     ancestors and switch. Deduped against SelectionChanged and double events.
        #  b) Form-level diagnostic - logs the hit element chain for every click, so if
        #     (a) never fires we can see what invisible element eats the input.
        $navView.add_PreviewMouseLeftButtonUp({
            param($clickSender, $clickArgs)
            $now = Get-Date
            if ($sync.NavClickAt -and (($now - $sync.NavClickAt).TotalMilliseconds -lt 500)) {
                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "nav preview: dedup drop"
                return
            }
            $tag = $null
            $chain = [System.Collections.Generic.List[string]]::new()
            try {
                $src = $clickArgs.OriginalSource
                while ($src) {
                    $chain.Add($src.GetType().Name)
                    if ($src -is [Windows.Controls.Control] -and $src.Tag -and "$($src.Tag)" -match '^WPFTab\d+$') {
                        $tag = "$($src.Tag)"; break
                    }
                    $src = [Windows.Media.VisualTreeHelper]::GetParent($src)
                }
            } catch { }
            $chainTxt = ($chain | Select-Object -First 6) -join '>'
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("nav preview: tag=[$tag] chain=[$chainTxt] before=[$($sync.currentTab)]")
            if ($tag) {
                $sync.NavClickAt = $now
                # consume the SelectionChanged raised by this same physical click
                $sync.NavSyncing = $true
                $sync.NavSyncingAt = $now
                Invoke-WPFTab $tag
            }
        })

        $sync["Form"].Add_PreviewMouseLeftButtonUp({
            param($formSender, $formArgs)
            try {
                $chain = [System.Collections.Generic.List[string]]::new()
                $src = $formArgs.OriginalSource
                while ($src -and $chain.Count -lt 6) {
                    $chain.Add($src.GetType().Name)
                    $src = [Windows.Media.VisualTreeHelper]::GetParent($src)
                }
                $p = $formArgs.GetPosition($sync.Form)
                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("form click: pos=[$([Math]::Round($p.X)),$([Math]::Round($p.Y))] chain=[" + (($chain | Select-Object -First 5) -join '>') + "]")
            } catch { }
        })
    }

    # --- 一次性真机外壳诊断:窗口到底以什么样式存在(临时,排查双标题栏) ---
    $sync["Form"].Add_ContentRendered({
        # NavigationView's template parts only exist after the first layout pass.
        # Rebind them here (the startup theme/language calls ran before the template
        # was applied), then every later theme change refreshes them again.
        try { Set-WinUtilNavViewAppearance } catch {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "NavView Loaded rebind failed: $($_.Exception.Message)"
        }
        try {
            if (-not ('WinUtil.ChromeDiag' -as [type])) {
                Add-Type -ReferencedAssemblies @('PresentationCore','WindowsBase','System.Xaml','System.Drawing') @"
using System;
using System.Runtime.InteropServices;
namespace WinUtil {
    public static class ChromeDiag {
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
        [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
        [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
        public const int GWL_STYLE = -16;
        public const int WS_CAPTION = 0x00C00000;
        public const int WS_SYSMENU = 0x00080000;
        public const int WS_MINIMIZEBOX = 0x00020000;
        public const int WS_MAXIMIZEBOX = 0x00010000;
        public const int WS_THICKFRAME = 0x00040000;
    }
}
"@
            }
            $h = [Windows.Interop.WindowInteropHelper]::new($sync.Form).Handle
            $d = @()
            $d += ("WindowStyle=" + $sync.Form.WindowStyle)
            $d += ("ResizeMode=" + $sync.Form.ResizeMode)
            $chrome = [Windows.Shell.WindowChrome]::GetWindowChrome($sync.Form)
            $d += ("windowChrome=" + $(if ($chrome) { "glass=" + $chrome.GlassFrameThickness.ToString() + " capH=" + $chrome.CaptionHeight + " aero=" + $chrome.UseAeroCaptionButtons } else { 'null' }))
            $st = [WinUtil.ChromeDiag]::GetWindowLong($h, [WinUtil.ChromeDiag]::GWL_STYLE)
            $d += ("GWL_STYLE=0x{0:X8} cap={1} sysmenu={2} minbox={3} maxbox={4} thick={5}" -f $st,
                [bool]($st -band [WinUtil.ChromeDiag]::WS_CAPTION),
                [bool]($st -band [WinUtil.ChromeDiag]::WS_SYSMENU),
                [bool]($st -band [WinUtil.ChromeDiag]::WS_MINIMIZEBOX),
                [bool]($st -band [WinUtil.ChromeDiag]::WS_MAXIMIZEBOX),
                [bool]($st -band [WinUtil.ChromeDiag]::WS_THICKFRAME))
            $wr = New-Object WinUtil.ChromeDiag+R
            [void][WinUtil.ChromeDiag]::GetWindowRect($h, [ref]$wr)
            $pt = New-Object WinUtil.ChromeDiag+P
            $pt.X = 0; $pt.Y = 0
            [void][WinUtil.ChromeDiag]::ClientToScreen($h, [ref]$pt)
            $d += ("topNonClient=" + ($pt.Y - $wr.T) + "px")
            # Decisive flag: ModernWpf's implicit Window.Template contains
            # ui:TitleBarControl (client-area Row 0). Our XAML-local template must win.
            $tplX = ''
            try { if ($sync.Form.Template) { $tplX = [Windows.Markup.XamlWriter]::Save($sync.Form.Template) } } catch { }
            $d += ("templateHasTitleBarControl=" + [bool]($tplX -match 'TitleBarControl'))
            $d += ("templateLen=" + $tplX.Length)
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("chrome diag: " + ($d -join '; '))
        } catch {
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("chrome diag failed: " + $_.Exception.Message)
        }
    })

    # --- 一次性运行时诊断探针:隐式样式实化 + 画刷解析 + 卡片区结构(临时,排查界面错乱) ---
    $sync["Form"].Add_ContentRendered({
        try {
            $p = @()
            $md = $sync.Form.Resources.MergedDictionaries
            $p += ("merged=" + (($md | ForEach-Object { $_.GetType().Name }) -join '/'))
            $p += ("wpfTitle=[" + $sync.Form.Title + "]")
            # 运行时真实按钮:隐式样式到底给了什么
            $btn = New-Object Windows.Controls.Button
            $root = $sync.Form.Content
            if ($root -and $root.Children) { [void]$root.Children.Add($btn) } else { $p += "root-no-children" }
            $tplSetter = $null
            if ($btn.Style) {
                $tplSetter = $btn.Style.Setters | Where-Object { $_ -is [Windows.Setter] -and $_.Property -eq [Windows.Controls.Control]::TemplateProperty } | Select-Object -First 1
                $p += ("implicitBtn: setters=" + $btn.Style.Setters.Count + " tpl=" + $(if ($tplSetter) { 'yes' } else { 'no' }))
            } else { $p += "implicitBtn: style=NULL" }
            $p += ("btn bg=" + $(if ($btn.Background) { $btn.Background.GetType().Name } else { 'null' }) + " tplProp=" + $(if ($btn.Template) { 'yes' } else { 'no' }))
            if ($tplSetter) {
                try {
                    $tplXaml = [Windows.Markup.XamlWriter]::Save($tplSetter.Value)
                    [IO.File]::WriteAllText((Join-Path $env:TEMP 'mw-runtime-template.txt'), $tplXaml)
                    $p += ("tplDump=" + $tplXaml.Length + "B")
                } catch { $p += ("tplDump failed: " + $_.Exception.Message) }
            }
            if ($root -and $root.Children -and $root.Children.Contains($btn)) { $root.Children.Remove($btn) }
            # 画刷键探测
            foreach ($k in @('ControlFillColorDefaultBrush','SystemControlBackgroundListMediumBrush','SystemControlForegroundBaseHighBrush','SystemAccentColor','FluentBtnBg','MainBackgroundColor')) {
                $v = $sync.Form.TryFindResource($k)
                $p += ($k + "=" + $(if ($v) { $v.GetType().Name } else { 'NULL' }))
            }
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("runtime probe: " + ($p -join '; '))

            # Titlebar controls probe: theme/font/settings buttons must be visible AND
            # their glyph rendered (HoverButtonStyle Opacity=0 regression check), plus
            # language/theme menu items and popup PlacementTarget resolution.
            $tc = @()
            foreach ($n in @('ThemeButton','FontScalingButton','SettingsButton','JobQueueButton')) {
                $e = $sync.Form.FindName($n)
                if ($e) {
                    $tc += ("$n vis=$($e.Visibility) loaded=$($e.IsLoaded) w=$([Math]::Round($e.ActualWidth)) h=$([Math]::Round($e.ActualHeight)) content=[$($e.Content)]")
                } else { $tc += "$n=NULL" }
            }
            foreach ($n in @('LangEnMenuItem','LangZhMenuItem','AutoThemeMenuItem','DarkThemeMenuItem')) {
                $e = $sync.Form.FindName($n)
                if ($e) { $tc += ("$n vis=$($e.Visibility) header=[$($e.Header)]") } else { $tc += "$n=NULL" }
            }
            foreach ($n in @('ThemePopup','SettingsPopup','FontScalingPopup','JobQueuePopup')) {
                $e = $sync.Form.FindName($n)
                if ($e) { $tc += ("$n target=$(if($e.PlacementTarget){$e.PlacementTarget.Name}else{'NULL'}) open=$($e.IsOpen)") } else { $tc += "$n=NULL" }
            }
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("titlebar controls: " + ($tc -join '; '))

            # Nav pane probe: light/dark theme coverage + explicit language walk.
            $np = @()
            foreach ($k in @('MainBackgroundColor','MainForegroundColor')) {
                $b = $sync.Form.TryFindResource($k)
                $np += ("$k=$(if($b -and $b -is [Windows.Media.SolidColorBrush]){$b.Color}else{'?'})")
            }
            $nv = $sync.Form.FindName('WPFNavView')
            if ($nv) {
                $np += ("navItems=[" + ((@($nv.MenuItems) | ForEach-Object { $_.Content }) -join '/') + "]")
                $np += ("navItem0Fg=$(if($nv.MenuItems.Count -and $nv.MenuItems[0].Foreground -is [Windows.Media.SolidColorBrush]){$nv.MenuItems[0].Foreground.Color}else{'?'})")
                # template parts are in nested templates; walk visual tree by name
                $qnv = [System.Collections.Generic.Queue[object]]::new()
                $qnv.Enqueue($nv); $nseen = 0; $navParts = @{}
                while ($qnv.Count -gt 0 -and $nseen -lt 9000) {
                    $vv = $qnv.Dequeue(); $nseen++
                    if ($vv -is [Windows.DependencyObject]) {
                        $nn = ''
                        try { $nn = [string]$vv.GetValue([Windows.FrameworkElement]::NameProperty) } catch {}
                        if ($nn -in @('PaneRoot','LayoutRoot','TogglePaneButton') -and -not $navParts.ContainsKey($nn)) { $navParts[$nn] = $vv }
                        try { $cc = [Windows.Media.VisualTreeHelper]::GetChildrenCount($vv); for($ii=0;$ii -lt $cc;$ii++){ $qnv.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($vv,$ii)) } } catch {}
                    }
                }
                foreach ($pk in @('PaneRoot','LayoutRoot','TogglePaneButton')) {
                    $pe = $navParts[$pk]
                    if ($pe) {
                        $pb = if ($pe -is [Windows.Controls.Panel]) { $pe.Background } elseif ($pe -is [Windows.Controls.Control]) { $pe.Background } else { $null }
                        $np += ("$pk.bg=$(if($pb -and $pb -is [Windows.Media.SolidColorBrush]){$pb.Color}else{'?'})")
                    } else { $np += "$pk=missing" }
                }
            } else { $np += "WPFNavView=NULL" }
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("nav pane: " + ($np -join '; '))

            $q = @()
            $ic = $sync.ItemsControl
            if ($ic) {
                $q += ("items=" + $ic.Items.Count)
                if ($ic.Items.Count -gt 0 -and $ic.Items[0].Children.Count -ge 2) {
                    $wp = $ic.Items[0].Children[1]
                    $q += ("wrap0.children=" + $wp.Children.Count + " vis=" + $wp.Visibility)
                }
            } else { $q += "ItemsControl=null" }
            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("area probe: " + ($q -join '; '))

            # 卡片队列状态探针(8 秒后一次性,验证后台队列是否真的把卡片建出来了)
            $qt = New-Object System.Windows.Threading.DispatcherTimer
            $qt.Interval = [timespan]::FromSeconds(8)
            $qt.Add_Tick({
                param($qSender)
                $tick = [System.Windows.Threading.DispatcherTimer]$qSender
                $tick.Stop()
                try {
                    $r = @()
                    $r += ("queue.Count=" + $sync.InstallAppRenderQueue.Count)
                    $r += ("bgQueues=[" + (($sync.BackgroundQueues.Keys | ForEach-Object { "$($_):$($sync.BackgroundQueues[$_].Queue.Count)" }) -join ' ') + "]")
                    $r += ("currentTab=" + $sync.currentTab)
                    $ic2 = $sync.ItemsControl
                    if ($ic2) {
                        $r += ("items=" + $ic2.Items.Count)
                        $total = 0
                        foreach ($cat in $ic2.Items) { if ($cat.Children.Count -ge 2) { $total += $cat.Children[1].Children.Count } }
                        $r += ("cardsTotal=" + $total)
                        if ($ic2.Items.Count -gt 0 -and $ic2.Items[0].Children.Count -ge 2) {
                            $wp2 = $ic2.Items[0].Children[1]
                            if ($wp2.Children.Count -gt 0) {
                                $c = $wp2.Children[0]
                                $r += ("card0=" + $c.GetType().Name + " vis=" + $c.Visibility + " w=" + [Math]::Round($c.ActualWidth) + " h=" + [Math]::Round($c.ActualHeight) + " style=" + $(if ($c.Style) { 'set' } else { 'null' }))
                            }
                        }
                    }
                    Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("queue probe: " + ($r -join '; '))
                    # --- self-capture: this process owns the window, so no UIPI / occlusion.
                    # RenderTargetBitmap renders the actual visual tree (any TitleBarControl
                    # injected by an implicit template shows up here, pixel-provable).
                    try {
                        $fw = [Math]::Ceiling($sync.Form.ActualWidth)
                        $fh = [Math]::Ceiling($sync.Form.ActualHeight)
                        if ($fw -gt 0 -and $fh -gt 0) {
                            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($fw, $fh, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                            $rtb.Render($sync.Form)
                            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                            $fs = [IO.File]::Open((Join-Path $env:TEMP 'winutil-self-visual.png'), [IO.FileMode]::Create)
                            $enc.Save($fs); $fs.Close()
                            # Screen-DC pixel truth as well (window is ours; force top first).
                            $hh = [Windows.Interop.WindowInteropHelper]::new($sync.Form).Handle
                            $rr = New-Object WinUtil.ChromeDiag+R
                            [void][WinUtil.ChromeDiag]::GetWindowRect($hh, [ref]$rr)
                            $cw = $rr.Rt - $rr.L; $chh = $rr.B - $rr.T
                            if ($cw -gt 0 -and $chh -gt 0) {
                                $bmp = New-Object System.Drawing.Bitmap($cw, $chh)
                                $gg = [System.Drawing.Graphics]::FromImage($bmp)
                                $gg.CopyFromScreen($rr.L, $rr.T, 0, 0, (New-Object System.Drawing.Size($cw, $chh)))
                                $bmp.Save((Join-Path $env:TEMP 'winutil-self-screen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
                                $gg.Dispose(); $bmp.Dispose()
                            }
                            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("self-capture: visual ${fw}x${fh} + screen ok")
                        }
                     } catch {
                        Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("self-capture failed: " + $_.Exception.Message)
                    }

                    # --- opt-in tweaks-view e2e (flag file, normal runs never trigger) ---
                    # The real click is performed by the external verifier via SendInput.
                    # Here we only switch to the Tweaks tab programmatically so the
                    # same-process screenshot covers the CJK-heavy rows being verified.
                    try {
                        $flag = Join-Path $env:TEMP 'winutil-e2e-navclick.flag'
                        $uninstFlag = Join-Path $env:TEMP 'winutil-e2e-uninstall.flag'
                        $macFlag = Join-Path $env:TEMP 'winutil-e2e-mac.flag'
                        $officeFlag = Join-Path $env:TEMP 'winutil-e2e-office.flag'
                        $reinstallFlag = Join-Path $env:TEMP 'winutil-e2e-reinstall.flag'
                        # Round 13: one capture timer for both opt-in e2e modes. The Uninstall
                        # tab is delayed longer (its 468-item scan runs in a worker) and gets a
                        # second same-process capture after switching to the Startup view.
                        # Round 14: the MAC tab joins the same timer (read-only probe; never
                        # touches NetworkAddress or restarts an adapter).
                        $e2eTab = $null
                        if (Test-Path $uninstFlag) { $e2eTab = 'WPFTab7' }
                        elseif (Test-Path $macFlag) { $e2eTab = 'WPFTab8' }
                        elseif (Test-Path $officeFlag) { $e2eTab = 'WPFTab9' }
                        elseif (Test-Path $reinstallFlag) { $e2eTab = 'WPFTab10' }
                        elseif (Test-Path $flag) { $e2eTab = 'WPFTab2' }
                        if ($e2eTab) {
                            Invoke-WPFTab $e2eTab
                            $e2eLabel = if ($e2eTab -eq 'WPFTab7') { 'uninstall tab e2e' } elseif ($e2eTab -eq 'WPFTab8') { 'mac tab e2e' } elseif ($e2eTab -eq 'WPFTab9') { 'office tab e2e' } elseif ($e2eTab -eq 'WPFTab10') { 'reinstall tab e2e' } else { 'tweaks view e2e' }
                            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("$e2eLabel : switched to $e2eTab; currentTab=[$($sync.currentTab)]")
                            $ft = New-Object System.Windows.Threading.DispatcherTimer
                            $ft.Interval = [TimeSpan]::FromSeconds($(if ($e2eTab -eq 'WPFTab7') { 6 } elseif ($e2eTab -eq 'WPFTab8' -or $e2eTab -eq 'WPFTab9' -or $e2eTab -eq 'WPFTab10') { 4 } else { 4 }))
                            $ft.Add_Tick({
                                    param($s2)
                                    $s2.Stop()
                                    try {
                                        $fw2 = [Math]::Ceiling($sync.Form.ActualWidth)
                                        $fh2 = [Math]::Ceiling($sync.Form.ActualHeight)
                                        $rtb2 = New-Object Windows.Media.Imaging.RenderTargetBitmap($fw2, $fh2, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                                        $rtb2.Render($sync.Form)
                                        $enc2 = New-Object Windows.Media.Imaging.PngBitmapEncoder
                                        $enc2.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb2))
                                        $fs2 = [IO.File]::Open((Join-Path $env:TEMP 'winutil-self-visual-afterclick.png'), [IO.FileMode]::Create)
                                        $enc2.Save($fs2); $fs2.Close()
                                        Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("nav click e2e: after-capture ok; currentTab=[$($sync.currentTab)]")
                                        # Round 13: Uninstall tab data probe (log only, read-only).
                                        try {
                                            if ($sync.currentTab -eq 'Uninstall Applications') {
                                                $pl = if ($sync.ContainsKey('WPFUninstProgramList')) { $sync['WPFUninstProgramList'] } else { $null }
                                                $sl = if ($sync.ContainsKey('WPFUninstStartupList')) { $sync['WPFUninstStartupList'] } else { $null }
                                                $pc = if ($pl) { @($pl.ItemsSource).Count } else { -1 }
                                                $sc = if ($sl) { @($sl.ItemsSource).Count } else { -1 }
                                                $bg = if ($pl) { $pl.Background.ToString() } else { 'null' }
                                                $fg = if ($pl) { $pl.Foreground.ToString() } else { 'null' }
                                                $tool = $sync['WPFUninstLaunchTool']
                                                $toolOn = if ($tool) { $tool.IsEnabled } else { 'missing' }
                                                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("uninstall tab probe: currentTab=[$($sync.currentTab)] programRows=$pc startupRows=$sc listBg=$bg listFg=$fg toolEnabled=$toolOn loaded=[$($sync.UninstallDataLoaded)]")
                                            }
                                        } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("uninstall tab probe failed: " + $_.Exception.Message) }
                                        # Round 14: MAC tab data probe (log only, read-only - never
                                        # writes NetworkAddress or restarts an adapter).
                                        try {
                                            if ($sync.currentTab -eq 'Change MAC Address') {
                                                $ml = if ($sync.ContainsKey('WPFMacAdapterList')) { $sync['WPFMacAdapterList'] } else { $null }
                                                $mc = if ($ml) { @($ml.ItemsSource).Count } else { -1 }
                                                $mfg = if ($ml) { $ml.Foreground.ToString() } else { 'null' }
                                                $mDetailVis = if ($sync.ContainsKey('WPFMacDetailGrid')) { $sync['WPFMacDetailGrid'].Visibility } else { 'missing' }
                                                $mLoaded = if ($sync.ContainsKey('MacDataLoaded')) { $sync.MacDataLoaded } else { $false }
                                                $mSel = if ($ml -and $ml.SelectedItem) { $ml.SelectedItem.Id } else { 'none' }
                                                $mStatus = if ($sync.ContainsKey('WPFMacStatus')) { $sync['WPFMacStatus'].Text } else { '' }
                                                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("mac tab probe: currentTab=[$($sync.currentTab)] adapterRows=$mc listFg=$mfg detailVis=$mDetailVis loaded=[$mLoaded] selected=[$mSel] status=[$mStatus]")
                                                # Select the first adapter so the screenshot shows the
                                                # details panel and traffic block populated.
                                                if ($ml -and @($ml.ItemsSource).Count -gt 0 -and -not $ml.SelectedItem) {
                                                    $ml.SelectedIndex = 0
                                                    Set-WinUtilMacDetails $ml.SelectedItem
                                                }
                                                $mft2 = New-Object System.Windows.Threading.DispatcherTimer
                                                $mft2.Interval = [TimeSpan]::FromSeconds(2)
                                                $mft2.Add_Tick({
                                                        param($s4)
                                                        $s4.Stop()
                                                        try {
                                                            $fw4 = [Math]::Ceiling($sync.Form.ActualWidth)
                                                            $fh4 = [Math]::Ceiling($sync.Form.ActualHeight)
                                                            $rtb4 = New-Object Windows.Media.Imaging.RenderTargetBitmap($fw4, $fh4, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                                                            $rtb4.Render($sync.Form)
                                                            $enc4 = New-Object Windows.Media.Imaging.PngBitmapEncoder
                                                            $enc4.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb4))
                                                            $fs4 = [IO.File]::Open((Join-Path $env:TEMP 'winutil-self-visual-mac.png'), [IO.FileMode]::Create)
                                                            $enc4.Save($fs4); $fs4.Close()
                                                            $ml4 = $sync['WPFMacAdapterList']
                                                            $sel4 = if ($ml4 -and $ml4.SelectedItem) { $ml4.SelectedItem.Id } else { 'none' }
                                                            $tr4 = if ($sync.ContainsKey('WPFMacTraffic')) { $sync['WPFMacTraffic'].Text } else { '' }
                                                            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("mac traffic probe: selected=[$sel4] traffic=[$tr4]")
                                                        } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("mac traffic capture failed: " + $_.Exception.Message) }
                                                    })
                                                $mft2.Start()
                                            }
                                        } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("mac tab probe failed: " + $_.Exception.Message) }
                                        # Round 15: Office Deployment tab probe (log only, read-only -
                                        # never deploys Office nor touches any activation state).
                                        try {
                                            if ($sync.currentTab -eq 'Office Deployment') {
                                                $pp = if ($sync.ContainsKey('WPFOfficeProduct')) { $sync['WPFOfficeProduct'] } else { $null }
                                                $pv = if ($sync.ContainsKey('WPFOfficeConfigPreview')) { $sync['WPFOfficeConfigPreview'].Text } else { '' }
                                                $ws = if ($sync.ContainsKey('WPFOfficeWinStatus')) { $sync['WPFOfficeWinStatus'].Text } else { '' }
                                                $os = if ($sync.ContainsKey('WPFOfficeOffStatus')) { $sync['WPFOfficeOffStatus'].Text } else { '' }
                                                $prodCount = if ($pp) { @($pp.ItemsSource).Count } else { -1 }
                                                $selProd = if ($pp -and $pp.SelectedItem) { $pp.SelectedItem } else { 'none' }
                                                $hasSchema = if ($pv -match 'OfficeClientEdition' -and $pv -match '<Display') { $true } else { $false }
                                                $hasExclude = if ($pv -match 'ExcludeApp') { $true } else { $false }
                                                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("office tab probe: currentTab=[$($sync.currentTab)] products=$prodCount selected=[$selProd] schemaOk=[$hasSchema] excludeApp=[$hasExclude] winStatus=[$ws] offStatus=[$os] previewLen=$($pv.Length)")
                                            }
                                        } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("office tab probe failed: " + $_.Exception.Message) }
                                        # Reinstall (hidden high-risk external entry) tab probe (log only, read-only -
                                        # never clicks Prepare / Start / Cancel and never calls any reinstall worker function).
                                        try {
                                            if ($sync.currentTab -eq 'Windows Reinstall') {
                                                $riso = if ($sync.ContainsKey('WPFReinstallIsoUrl')) { $sync['WPFReinstallIsoUrl'] } else { $null }
                                                $rimg = if ($sync.ContainsKey('WPFReinstallImageName')) { $sync['WPFReinstallImageName'] } else { $null }
                                                $rack = if ($sync.ContainsKey('WPFReinstallAckCheck')) { $sync['WPFReinstallAckCheck'] } else { $null }
                                                $rprep = if ($sync.ContainsKey('WPFReinstallPrepareButton')) { $sync['WPFReinstallPrepareButton'] } else { $null }
                                                $rstart = if ($sync.ContainsKey('WPFReinstallStartButton')) { $sync['WPFReinstallStartButton'] } else { $null }
                                                $rcancel = if ($sync.ContainsKey('WPFReinstallCancelButton')) { $sync['WPFReinstallCancelButton'] } else { $null }
                                                $rstatus = if ($sync.ContainsKey('WPFReinstallStatus')) { $sync['WPFReinstallStatus'] } else { $null }
                                                $rpreview = if ($sync.ContainsKey('WPFReinstallCommandPreview')) { $sync['WPFReinstallCommandPreview'] } else { $null }
                                                $rcopy = if ($sync.ContainsKey('WPFReinstallCopyButton')) { $sync['WPFReinstallCopyButton'] } else { $null }
                                                $risoBox = if ($riso -and $rimg) { 'yes' } else { 'none' }
                                                $rackVal = if ($rack) { $rack.IsChecked } else { 'missing' }
                                                $rprepare = if ($rprep) { $rprep.IsEnabled } else { 'missing' }
                                                $rstartVal = if ($rstart) { $rstart.IsEnabled } else { 'missing' }
                                                $rcancelVal = if ($rcancel) { $rcancel.IsEnabled } else { 'missing' }
                                                $rstatusLen = if ($rstatus) { $rstatus.Text.Length } else { -1 }
                                                $rcombo = if ($rimg -and $rimg -is [System.Windows.Controls.ComboBox]) { "editable=$($rimg.IsEditable);index=$($rimg.SelectedIndex);items=$(@($rimg.Items).Count)" } else { 'missing' }
                                                $rpreviewLen = if ($rpreview) { $rpreview.Text.Length } else { -1 }
                                                $rcopyVal = if ($rcopy) { 'yes' } else { 'none' }
                                                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("reinstall tab probe: currentTab=[$($sync.currentTab)] isoBox=[$risoBox] ack=[$rackVal] prepare=[$rprepare] start=[$rstartVal] cancel=[$rcancelVal] statusLen=$rstatusLen combo=[$rcombo] previewLen=$rpreviewLen copy=[$rcopyVal]")
                                                if ($rpreview) { Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("reinstall command preview: [$($rpreview.Text)]") }
                                            }
                                        } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("reinstall tab probe failed: " + $_.Exception.Message) }
                                        # Round 13: switch to the Startup view and take a second
                                        # same-process image once layout has settled. Both views
                                        # then have pixel evidence from the real shown window.
                                        if ($sync.currentTab -eq 'Uninstall Applications') {
                                            try {
                                                Set-WinUtilUninstallView -View 'Startup'
                                                $ft2 = New-Object System.Windows.Threading.DispatcherTimer
                                                $ft2.Interval = [TimeSpan]::FromSeconds(2)
                                                $ft2.Add_Tick({
                                                        param($s3)
                                                        $s3.Stop()
                                                        try {
                                                            $fw3 = [Math]::Ceiling($sync.Form.ActualWidth)
                                                            $fh3 = [Math]::Ceiling($sync.Form.ActualHeight)
                                                            $rtb3 = New-Object Windows.Media.Imaging.RenderTargetBitmap($fw3, $fh3, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                                                            $rtb3.Render($sync.Form)
                                                            $enc3 = New-Object Windows.Media.Imaging.PngBitmapEncoder
                                                            $enc3.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb3))
                                                            $fs3 = [IO.File]::Open((Join-Path $env:TEMP 'winutil-self-visual-startup.png'), [IO.FileMode]::Create)
                                                            $enc3.Save($fs3); $fs3.Close()
                                                            $sl3 = $sync['WPFUninstStartupList']
                                                            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("uninstall startup probe: startupRows=$(@($sl3.ItemsSource).Count) listVis=$($sl3.Visibility) currentTab=[$($sync.currentTab)]")
                                                        } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("uninstall startup capture failed: " + $_.Exception.Message) }
                                                    })
                                                $ft2.Start()
                                            } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("uninstall startup switch failed: " + $_.Exception.Message) }
                                        }
                                        # Row/control height probe for CJK clipping verification (log only).
                                        try {
                                            $tp2 = $sync.Form.FindName('tweakspanel')
                                            $rowAcc = [System.Collections.Generic.List[string]]::new()
                                            if ($tp2) {
                                                $todo = [System.Collections.Generic.List[object]]::new()
                                                $todo.Add($tp2)
                                                while ($todo.Count -gt 0 -and $rowAcc.Count -lt 5) {
                                                    $node = $todo[0]; $todo.RemoveAt(0)
                                                    if ($node -is [Windows.Controls.DockPanel] -and $node.MinHeight -gt 0) {
                                                        $rowAcc.Add([string][Math]::Round($node.ActualHeight, 1))
                                                    }
                                                    $cn = [Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                                                    for ($k = 0; $k -lt $cn; $k++) {
                                                        $ch = [Windows.Media.VisualTreeHelper]::GetChild($node, $k)
                                                        if ($null -ne $ch) { $todo.Add($ch) }
                                                    }
                                                }
                                            }
                                            $bh = @()
                                            foreach ($bn in @('WPFTweaksbutton', 'WPFUndoall')) {
                                                $be = $sync.Form.FindName($bn)
                                                if ($be) { $bh += "$bn=$([Math]::Round($be.ActualHeight,1))" }
                                            }
                                            Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("tweaks layout probe: currentTab=[$($sync.currentTab)] rows=[" + ($rowAcc -join ',') + "] buttons=[" + ($bh -join ' ') + "]")
                                            # ComboBox color probe (round 11): resolved brushes must follow the theme.
                                            # Generated controls live in $sync, not the XAML NameScope.
                                            try {
                                                $cbRes = @()
                                                foreach ($rk in @('FluentFieldBg','FluentPopupBg','FluentListHover','FluentCheckedBg','SystemControlForegroundBaseHighBrush')) {
                                                    $rv = $sync.Form.Resources[$rk]
                                                    $rvTxt = if ($rv -is [Windows.Media.SolidColorBrush]) { $rv.Color.ToString() } elseif ($rv) { "$rv" } else { 'null' }
                                                    $cbRes += "$rk=$rvTxt"
                                                }
                                                $cb0 = if ($sync.ContainsKey('WPFchangedns')) { $sync['WPFchangedns'] } else { $null }
                                                if ($cb0) {
                                                    $cbRes += "comboBg=$(if($cb0.Background){$cb0.Background.ToString()}else{'null'})"
                                                    $cbRes += "comboFg=$(if($cb0.Foreground){$cb0.Foreground.ToString()}else{'null'})"
                                                }
                                                Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("combobox theme probe: " + ($cbRes -join '; '))

                                                # Same-process expanded-state capture: open the real generated
                                                # ComboBox, render its Popup child (own visual tree), close it.
                                                # UI-only; no SelectionChanged handler fires, no registry write.
                                                if ($cb0) {
                                                    $cb0.IsDropDownOpen = $true
                                                    $cb0.UpdateLayout()
                                                    $comboPopup = $null
                                                    $walk = [System.Collections.Generic.List[object]]::new()
                                                    $walk.Add($cb0)
                                                    while ($walk.Count -gt 0 -and -not $comboPopup) {
                                                        $node = $walk[0]; $walk.RemoveAt(0)
                                                        if ($node -is [Windows.Controls.Primitives.Popup]) { $comboPopup = $node; break }
                                                        $cc = [Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                                                        for ($ci = 0; $ci -lt $cc; $ci++) {
                                                            $cch = [Windows.Media.VisualTreeHelper]::GetChild($node, $ci)
                                                            if ($null -ne $cch) { $walk.Add($cch) }
                                                        }
                                                    }
                                                    if ($comboPopup -and $comboPopup.Child) {
                                                        $pc = $comboPopup.Child
                                                        $pc.Measure([Windows.Size]::new(320, [double]::PositiveInfinity))
                                                        $pc.Arrange([Windows.Rect]::new(0, 0, 320, $pc.DesiredSize.Height))
                                                        $pc.UpdateLayout()
                                                        $pw = [Math]::Ceiling($pc.ActualWidth); $ph = [Math]::Ceiling($pc.ActualHeight)
                                                        if ($pw -lt 1) { $pw = 320 }
                                                        if ($ph -lt 1) { $ph = [Math]::Ceiling($pc.DesiredSize.Height) }
                                                        $prtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                                                        $prtb.Render($pc)
                                                        $penc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                                                        $penc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($prtb))
                                                        $pfs = [IO.File]::Open((Join-Path $env:TEMP 'winutil-self-combo-popup.png'), [IO.FileMode]::Create)
                                                        $penc.Save($pfs); $pfs.Close()
                                                        Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message ("combobox popup probe: rendered ${pw}x${ph}; items=$($cb0.Items.Count)")
                                                    } else {
                                                        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "combobox popup probe: popup child not found"
                                                    }
                                                    $cb0.IsDropDownOpen = $false
                                                }
                                            } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("combobox popup probe failed: " + $_.Exception.Message) }
                                        } catch { }
                                    } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("nav click e2e after-capture failed: " + $_.Exception.Message) }
                                })
                                $ft.Start()
                        }
                    } catch { Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("tweaks view e2e failed: " + $_.Exception.Message) }
                } catch {
                    Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("queue probe failed: " + $_.Exception.Message)
                }
            })
            $qt.Start()
        } catch {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message ("runtime probe failed: " + $_.Exception.Message + " @ " + $_.InvocationInfo.ScriptLineNumber)
        }
    })

    # The default tab is built before the window is shown, in one pass nothing is waiting on, so it
    # opens with the app list in place instead of filling in. Offline starts on another tab.
    if (-not $PARAM_OFFLINE) {
        $sync.BuildingBeforeShow = $true
        try {
            Measure-WinUtilStep -Scope "UI" -Name "build default tab before show" -ScriptBlock { Invoke-WPFTab "WPFTab1BT" }
        } finally {
            $sync.BuildingBeforeShow = $false
        }
    }

    $sync["Form"].ShowDialog() | Out-Null

    # ShowDialog returns once the window is gone; stop the dispatcher so this runspace can close
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}