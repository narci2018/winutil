function Set-WinUtilNavViewAppearance {
    <#
    .SYNOPSIS
        Makes the ModernWpf NavigationView pane follow WinUtil's own theme resources.

    .DESCRIPTION
        The NavigationView template in ModernWpf 0.9.6 paints its pane with internal
        brushes (PaneRoot #FF252525, LayoutRoot/buttons #FF313131). Those values come
        from an implicit Style that is NOT connected to ThemeManager in this PowerShell
        host, so switching ThemeManager to Light or refreshing Form.Resources leaves
        the pane dark while the main content turns light.

        Offline probes (mw-style-probe10/12/13) established:
          - ThemeManager=Light does not change any pane part (changed=False).
          - The pane parts live in nested templates: ControlTemplate.FindName cannot
            find them, but a VisualTreeHelper walk by name finds 9/9.
          - SetResourceReference on those parts (Background -> MainBackgroundColor,
            Foreground -> MainForegroundColor) makes them follow the theme keys
            Invoke-WinutilThemeChange already refreshes, with no extra per-theme code.
          - NavigationViewItem objects in the MenuItems IList are neither in the
            logical tree nor in the visual tree before display, so a resource
            reference has no effect on their Foreground; it must be set as a local
            value from the resolved theme brush on every theme change.

        This function is safe to call repeatedly (once on window Loaded, then after
        every theme change). It never touches Content/Tag/Name or event handlers.
    #>
    param()

    $nav = $null
    if ($sync.ContainsKey('NavView') -and $sync.NavView) {
        $nav = $sync.NavView
    } elseif ($sync.Form) {
        # Startup order: theme/language are applied before $sync.NavView is assigned.
        # The XAML object itself is always available by name once parsed.
        try { $nav = $sync.Form.FindName('WPFNavView') } catch { }
    }
    if (-not $nav) { return }

    # Resolved theme brushes (already refreshed by Invoke-WinutilThemeChange).
    $bgBrush = $sync.Form.TryFindResource('MainBackgroundColor')
    $fgBrush = $sync.Form.TryFindResource('MainForegroundColor')
    if ($bgBrush -isnot [Windows.Media.SolidColorBrush]) { $bgBrush = [Windows.Media.Brushes]::Transparent }
    if ($fgBrush -isnot [Windows.Media.SolidColorBrush]) { $fgBrush = [Windows.Media.Brushes]::Black }

    # MenuItems are a CLR IList, not logical-tree children. Local values are required.
    foreach ($item in @($nav.MenuItems)) {
        if ($item -is [Windows.Controls.Control]) {
            $item.Foreground = $fgBrush
        }
    }

    # Dynamic bindings on the template parts: one-time setup, automatic theme follow.
    $names = @(
        'PaneRoot', 'LayoutRoot', 'RootGrid',
        'TogglePaneButton', 'NavigationViewBackButton', 'NavigationViewCloseButton',
        'TopNavOverflowButton', 'PaneAutoSuggestButton'
    )
    $found = @{}
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($nav)
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 9000) {
        $v = $queue.Dequeue()
        $visited++
        if ($v -is [Windows.DependencyObject]) {
            $nm = ''
            try { $nm = [string]$v.GetValue([Windows.FrameworkElement]::NameProperty) } catch { }
            if ($nm -and $names -contains $nm -and -not $found.ContainsKey($nm)) { $found[$nm] = $v }
            try {
                $count = [Windows.Media.VisualTreeHelper]::GetChildrenCount($v)
                for ($i = 0; $i -lt $count; $i++) {
                    $queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($v, $i))
                }
            } catch { }
        }
    }

    foreach ($nm in @('PaneRoot', 'LayoutRoot', 'RootGrid')) {
        $e = $found[$nm]
        if ($e -is [Windows.Controls.Panel]) {
            $e.SetResourceReference([Windows.Controls.Panel]::BackgroundProperty, 'MainBackgroundColor')
        }
    }
    foreach ($nm in @('TogglePaneButton', 'NavigationViewBackButton', 'NavigationViewCloseButton',
                     'TopNavOverflowButton', 'PaneAutoSuggestButton')) {
        $e = $found[$nm]
        if ($e -is [Windows.Controls.Control]) {
            $e.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'MainBackgroundColor')
            $e.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'MainForegroundColor')
        }
    }
}
