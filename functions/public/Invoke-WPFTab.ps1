function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    .PARAMETER Yield
        Build the tab's content in slices, letting the interface answer between them. For the
        tab opened at startup, where the window is already on screen and filling in gradually
        reads better than holding the thread until it is complete.

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab,

        [switch]$Yield
    )

    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab select" -ScriptBlock {
        $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
        $sync.WPFTabNav.Items[$tabNumber].IsSelected = $true
        ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
            if ($ClickedTab -ne $PSItem.name) {
                $sync[$PSItem.Name].IsChecked = $false
            } else {
                $sync["$ClickedTab"].IsChecked = $true
            }
        }
        # currentTab is the canonical tab key, never the localized Header: the render queue,
        # deferral checks and search filters compare it against "Install"/"Tweaks"/"AppX"
        # literals, and tab content is rebuilt through Initialize-WinUtilTabContent's switch.
        $tabKeyByIndex = @("Install", "Tweaks", "Config", "Updates", "Win11ISO", "AppX", "Uninstall Applications", "Change MAC Address", "Office Deployment", "Windows Reinstall")
        $sync.currentTab = $tabKeyByIndex[$tabNumber]
    }

    # Keep the NavigationView selection in sync with programmatic tab switches
    # (keyboard shortcuts, WPFAppxRemoval, startup). The NavSyncing guard prevents
    # the SelectionChanged handler from re-entering Invoke-WPFTab.
    if ($sync.ContainsKey('NavView') -and $sync.NavView) {
        try {
            $navTag = "WPFTab$($tabNumber + 1)"
            $navItem = @($sync.NavView.MenuItems) | Where-Object { $_.Tag -eq $navTag } | Select-Object -First 1
            if ($navItem -and -not [object]::ReferenceEquals($sync.NavView.SelectedItem, $navItem)) {
                $sync.NavSyncing = $true
                $sync.NavSyncingAt = Get-Date
                $sync.NavView.SelectedItem = $navItem
            }
        } catch { }
    }

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab content" -ScriptBlock {
        Initialize-WinUtilTabContent -TabName $sync.currentTab -Yield:$Yield
    }

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab filter reset" -ScriptBlock {
        $searchText = if ($null -ne $sync.SearchBar) { $sync.SearchBar.Text } else { "" }
        if ($sync.currentTab -eq "Install") {
            $selectedCategories = if ($sync.SelectedAppCategories) { $sync.SelectedAppCategories.ToArray() } else { @() }
            Find-AppsByNameOrDescription -SearchString $searchText -Categories $selectedCategories
        } elseif ($sync.currentTab -eq "Tweaks" -or $sync.currentTab -eq "AppX") {
            Find-TweaksByNameOrDescription -SearchString $searchText
        }
    }

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab search bar" -ScriptBlock {
        # Show search bar in Install, Tweaks, and AppX tabs
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($tabNumber -eq 0 -or $tabNumber -eq 1 -or $tabNumber -eq 5 -or $tabNumber -eq 6) {
            $sync.SearchBar.Visibility = "Visible"
            if ($searchIcon) { $searchIcon.Visibility = "Visible" }
        } else {
            $sync.SearchBar.Visibility = "Collapsed"
            if ($searchIcon) { $searchIcon.Visibility = "Collapsed" }
            $sync.SearchBarClearButton.Visibility = "Collapsed"
        }
    }
}
