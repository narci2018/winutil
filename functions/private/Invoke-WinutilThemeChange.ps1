function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # 颜色键按值格式判定(8/6 位 hex 一律 ColorBrush),键名匹配(*color*/*Brush/Fluent*)
            # 仅作补充——避免 ButtonForegroundDisabled、CaretBrush 这类不含 color/Brush 的键
            # 掉进 Double 分支(上游分类只看键名,主题扩展键在此静默失败)
            $isHexColor = $themeProperty.Value -is [string] -and $themeProperty.Value -match '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$'
            if ($isHexColor -or ($themeProperty.Name -like "*color*") -or ($themeProperty.Name -like "*Brush") -or ($themeProperty.Name -like "Fluent*")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor", "AppIconShadowColor", "MainGradientTopColor", "MainGradientBottomColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
                # Fluent 控件层的主题化:Fluent* 键若主题未自定义,回退到按语义映射的主题键,
                # 使强调色/描边/控件底色跟随每个主题的色相而非固定暗色
                $fluentFallback = @{
                    "FluentAccentBrush"       = "LabelboxForegroundColor"
                    "FluentAccentHoverBrush"  = "LinkHoverForegroundColor"
                    "FluentFieldBorderFocus"  = "LabelboxForegroundColor"
                    "FluentCheckedBg"         = "ButtonBackgroundSelectedColor"
                    "FluentBtnBorderHover"    = "ScrollBarHoverColor"
                    "FluentBtnBgHover"        = "ButtonBackgroundMouseoverColor"
                    "FluentBtnBgPressed"      = "ButtonBackgroundPressedColor"
                    "FluentBtnBgDisabled"     = "ButtonBackgroundColor"
                    "FluentFieldBg"           = "ComboBoxBackgroundColor"
                    "FluentPopupBg"           = "ToolTipBackgroundColor"
                    "FluentPopupBorder"       = "BorderColor"
                    "FluentSbThumbDrag"       = "LabelboxForegroundColor"
                }
                if ($themeProperty.Name -eq "ButtonBackgroundColor") {
                    foreach ($fluentName in @("FluentBtnBg", "FluentBtnBorder", "FluentFieldBorder", "FluentListPressed")) {
                        if (-not ($sync.configs.themes.$currentTheme.PSObject.Properties.Name -contains $fluentName)) {
                            Set-ThemeResourceProperty -Name $fluentName -Value $themeProperty.Value -Type "ColorBrush"
                        }
                    }
                }
                if ($fluentFallback.ContainsKey($themeProperty.Name)) {
                    # 主题已显式定义该 Fluent 键(上面的 *color* 分支已应用),不再覆盖
                    if ($sync.configs.themes.$currentTheme.PSObject.Properties.Name -contains $themeProperty.Name) {
                        continue
                    }
                    $fallbackKey = $fluentFallback[$themeProperty.Name]
                    $fallbackValue = $sync.configs.themes.$currentTheme.$fallbackKey
                    if ($fallbackValue) {
                        Set-ThemeResourceProperty -Name $themeProperty.Name -Value $fallbackValue -Type "ColorBrush"
                    }
                }
                # Mica support: an 8-digit hex background lets the desktop show through the
                # window base while opaque themes keep covering it entirely
                if ($themeProperty.Name -eq "MainBackgroundColor") {
                    $sync.MicaBackground = $themeProperty.Value -match '^#[0-9A-Fa-f]{8}$'
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    # Persist the choice so the next launch starts with the same theme
    try {
        $prefPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'winutil\preferences.json'
        $prefDir = Split-Path $prefPath -Parent
        if (-not (Test-Path $prefDir)) { New-Item -ItemType Directory -Path $prefDir -Force | Out-Null }
        $pref = if (Test-Path $prefPath) { Get-Content $prefPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        $pref | Add-Member -NotePropertyName theme -NotePropertyValue $theme -Force
        $pref | ConvertTo-Json -Depth 3 | Set-Content $prefPath -Encoding UTF8
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not persist theme preference: $($_.Exception.Message)"
    }

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
        default {
            # Any extra theme defined in config/themes.json (e.g. Cyberpunk, ClassicLight).
            # $sync.configs is a Hashtable: key membership goes through ContainsKey, not
            # PSObject.Properties (which only lists adapter properties on dictionaries).
            if ($sync.configs['themes'].PSObject.Properties.Name -contains $sync.preferences.theme) {
                Set-WinutilTheme -currentTheme $sync.preferences.theme
                $themeButtonIcon = [char]0xE790
            }
            else {
                Write-Warning "Unknown theme '$($sync.preferences.theme)', falling back to Auto."
                $sync.preferences.theme = "Auto"
                Set-WinutilTheme -currentTheme "Auto"
                $themeButtonIcon = [char]0xF08C
            }
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon

    # Modern chrome follows the theme: dark frame for dark themes, Mica backdrop when the
    # theme's MainBackgroundColor has an alpha channel (translucent base). The resolved
    # theme (Auto already expanded) is stored so the window Loaded hook can apply chrome
    # on first startup, where this function runs before the handle exists.
    $sync.LastResolvedTheme = $theme
    if ($sync.Form -and $sync.Form.IsLoaded) {
        $isDark = $theme -in @("Dark", "Cyberpunk", "Modern")
        Enable-WinUtilModernChrome -DarkMode:([bool]$isDark)
    }

    # ModernWpf 联动:控件层(Fluent)的明暗与强调色跟随主题,themes.json 的 BorderColor 即强调色
    if ($sync.ModernWpfLoaded) {
        try {
            $mwManager = [ModernWpf.ThemeManager]::Current
            if ($theme -in @("Light", "ClassicLight")) {
                $mwManager.ApplicationTheme = [ModernWpf.ApplicationTheme]::Light
            } else {
                $mwManager.ApplicationTheme = [ModernWpf.ApplicationTheme]::Dark
            }
            $mwThemeDef = $sync.configs['themes'].$theme
            if ($mwThemeDef -and $mwThemeDef.PSObject.Properties['BorderColor']) {
                try {
                    $mwAccent = [Windows.Media.ColorConverter]::ConvertFromString($mwThemeDef.BorderColor)
                    $mwManager.AccentColor = $mwAccent
                } catch { }
            }
        } catch {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "ThemeManager sync failed: $($_.Exception.Message)"
        }
    }

    # ModernWpf NavigationView pane uses internal dark brushes that neither ThemeManager
    # nor Form.Resources alone can reach. Rebind its template parts to our theme keys and
    # refresh MenuItems foreground (they are a CLR IList, not tree children).
    try { Set-WinUtilNavViewAppearance } catch {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "NavView appearance sync failed: $($_.Exception.Message)"
    }
}
