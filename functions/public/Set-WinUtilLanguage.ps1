function Set-WinUtilLanguage {
    <#
    .SYNOPSIS
        Applies a UI language to all translatable strings.

    .DESCRIPTION
        Reads $sync.configs.lang_<code> (embedded from config/lang_<code>.json at compile
        time) and rewrites user-visible text in three layers:

        1. Config-driven entries (apps, tweaks, features, appx, DNS): Content and
           description are overridden in place. Category is deliberately NOT translated:
           chip filtering and search compare categories in English.
        2. The whole WPF logical tree: string Content/Header/Text/ToolTip values are
           translated through the override table. Originals are snapshotted so switching
           back to English restores them exactly.
        3. Code-built UI goes through Get-WinUtilText / Get-WinUtilStatusText helpers.

        Application/brand names are kept in English by simply not having a key for them.
    #>
    param(
        [ValidateSet('en', 'zh-CN')]
        [string]$lang = 'en'
    )

    $sync.preferences.lang = $lang

    # Persist the choice next to the theme preference
    try {
        $prefPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'winutil\preferences.json'
        $prefDir = Split-Path $prefPath -Parent
        if (-not (Test-Path $prefDir)) { New-Item -ItemType Directory -Path $prefDir -Force | Out-Null }
        $pref = if (Test-Path $prefPath) { Get-Content $prefPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        $pref | Add-Member -NotePropertyName lang -NotePropertyValue $lang -Force
        $pref | ConvertTo-Json -Depth 3 | Set-Content $prefPath -Encoding UTF8
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not persist language preference: $($_.Exception.Message)"
    }

    # ---- Build the override table (English source -> translated) ----
    $overrides = $null
    # Config key matches the JSON file name: lang_zh-CN.json -> $sync.configs['lang_zh-CN'].
    # $sync.configs is a Hashtable: PSObject.Properties only exposes adapter properties
    # (Keys/Count/...), so key membership MUST be tested through the dictionary interface.
    $configKey = "lang_$lang"
    if ($lang -ne 'en' -and (Test-WinUtilConfigKey -Config $sync.configs -Key $configKey)) {
        $overrides = @{}
        $sync.configs[$configKey].PSObject.Properties | ForEach-Object {
            $overrides[$_.Name] = $_.Value
        }
    }
    $sync.LangOverrides = $overrides

    # Prefix-type keys (trailing space / open paren) drive Get-WinUtilStatusText; collecting
    # them once keeps every status update from scanning the full table
    $sync.I18nStatusPrefixKeys = if ($overrides) {
        @($overrides.Keys | Where-Object { $_ -match '( $|\($)' })
    } else {
        @()
    }

    # Reverse map (translated -> English) so controls that were rendered in the previous
    # language — including config-driven content and "- $Category" labels built with
    # Get-WinUtilText — can be restored exactly when switching back to English
    $sync.LangReverse = if ($overrides) {
        $rev = @{}
        foreach ($p in $overrides.GetEnumerator()) { $rev[$p.Value] = $p.Key }
        $rev
    } else {
        @{}
    }

    # ---- Config-driven entries: snapshot once, then translate / restore ----
    # Category is intentionally excluded: filtering logic compares English category values
    $configVars = @('applications', 'tweaks', 'feature', 'appx', 'dns', 'appnavigation', 'preset')
    if (-not $sync.ContainsKey('I18nConfigOriginals')) {
        $sync.I18nConfigOriginals = @{}
        foreach ($cv in $configVars) {
            if (-not (Test-WinUtilConfigKey -Config $sync.configs -Key $cv)) { continue }
            $snap = @{}
            foreach ($p in $sync.configs.$cv.PSObject.Properties) {
                $entry = @{}
                if ($null -ne $p.Value.PSObject.Properties['Content']) { $entry['Content'] = $p.Value.Content }
                if ($null -ne $p.Value.PSObject.Properties['description']) { $entry['description'] = $p.Value.description }
                if ($null -ne $p.Value.PSObject.Properties['Description']) { $entry['Description'] = $p.Value.Description }
                if ($p.Value.ComboDescriptions) {
                    $combo = @{}
                    foreach ($ck in $p.Value.ComboDescriptions.PSObject.Properties) { $combo[$ck.Name] = $ck.Value }
                    $entry['ComboDescriptions'] = $combo
                }
                if ($entry.Count -gt 0) { $snap[$p.Name] = $entry }
            }
            $sync.I18nConfigOriginals[$cv] = $snap
        }
    }

    foreach ($cv in $configVars) {
        if (-not $sync.I18nConfigOriginals.ContainsKey($cv)) { continue }
        if (-not (Test-WinUtilConfigKey -Config $sync.configs -Key $cv)) { continue }
        $snap = $sync.I18nConfigOriginals[$cv]
        foreach ($p in $sync.configs.$cv.PSObject.Properties) {
            $orig = $snap[$p.Name]
            if (-not $orig) { continue }
            # Restore English first, then apply the active language's override
            foreach ($field in @('Content', 'description', 'Description')) {
                if (-not $orig.ContainsKey($field)) { continue }
                $value = $orig[$field]
                if ($overrides -and $value -and $overrides.ContainsKey($value)) { $value = $overrides[$value] }
                $p.Value.$field = $value
            }
            if ($orig.ContainsKey('ComboDescriptions') -and $p.Value.ComboDescriptions) {
                foreach ($ck in $orig['ComboDescriptions'].Keys) {
                    $value = $orig['ComboDescriptions'][$ck]
                    if ($overrides -and $overrides.ContainsKey($value)) { $value = $overrides[$value] }
                    $p.Value.ComboDescriptions.($ck) = $value
                }
            }
        }
    }

    # ---- Walk the logical tree: snapshot string texts once, then translate / restore ----
    if (-not $sync.ContainsKey('I18nTreeOriginals')) {
        $sync.I18nTreeOriginals = @{}
    }
    $treeOriginals = $sync.I18nTreeOriginals

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $visited = [System.Collections.Generic.HashSet[object]]::new()
    $stack.Push($sync.Form)

    while ($stack.Count -gt 0) {
        $el = $stack.Pop()
        if ($null -eq $el) { continue }
        if (-not $visited.Add($el)) { continue }

        # Queue children first so the property writes below cannot disturb the walk
        try {
            foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($el)) {
                if ($null -ne $child) { $stack.Push($child) }
            }
        } catch { }

        # Context menus live outside the logical tree until opened
        try {
            if ($el -is [Windows.FrameworkElement] -and $el.ContextMenu) { $stack.Push($el.ContextMenu) }
        } catch { }

        $isEnglish = $lang -eq 'en' -or -not $overrides

        if ($el -is [Windows.Controls.TextBlock]) {
            $entry = $treeOriginals[$el]
            if (-not $entry) { $entry = @{}; $treeOriginals[$el] = $entry }
            if (-not $entry.ContainsKey('Text')) { $entry['Text'] = $el.Text }
            $orig = $entry['Text']
            $target = if ($isEnglish) { $orig } elseif ($orig -and $overrides.ContainsKey($orig)) { $overrides[$orig] } else { $orig }
            if ($el.Text -cne $target) { $el.Text = $target }
        }

        foreach ($pair in @(
            @{ Type = [Windows.Controls.ContentControl]; Prop = 'Content' },
            @{ Type = [Windows.Controls.HeaderedContentControl]; Prop = 'Header' },
            @{ Type = [Windows.Controls.HeaderedItemsControl]; Prop = 'Header' }
        )) {
            if ($el -is $pair.Type) {
                $prop = $pair.Prop
                $current = $el.$prop
                if ($current -is [string]) {
                    $entry = $treeOriginals[$el]
                    if (-not $entry) { $entry = @{}; $treeOriginals[$el] = $entry }
                    if (-not $entry.ContainsKey($prop)) { $entry[$prop] = $current }
                    $orig = $entry[$prop]
                    $target = if ($isEnglish) { $orig } elseif ($orig -and $overrides.ContainsKey($orig)) { $overrides[$orig] } else { $orig }
                    if ($el.$prop -cne $target) { $el.$prop = $target }
                }
            }
        }

        if ($el -is [Windows.FrameworkElement] -and $el.ToolTip -is [string]) {
            $entry = $treeOriginals[$el]
            if (-not $entry) { $entry = @{}; $treeOriginals[$el] = $entry }
            if (-not $entry.ContainsKey('ToolTip')) { $entry['ToolTip'] = $el.ToolTip }
            $orig = $entry['ToolTip']
            $target = if ($isEnglish) { $orig } elseif ($orig -and $overrides.ContainsKey($orig)) { $overrides[$orig] } else { $orig }
            if ($el.ToolTip -cne $target) { $el.ToolTip = $target }
        }
    }

    # ---- GridView column headers (round 13 Uninstall tab) ----
    # GridViewColumn is not a Visual, so the logical-tree walk above never sees it.
    # Translate each column's Header explicitly with the same snapshot/restore scheme.
    foreach ($listName in @('WPFUninstProgramList', 'WPFUninstStartupList', 'WPFMacAdapterList')) {
        $lv = $null
        if ($sync.ContainsKey($listName) -and $sync[$listName]) { $lv = $sync[$listName] }
        elseif ($sync.Form) { try { $lv = $sync.Form.FindName($listName) } catch { } }
        if (-not $lv -or -not $lv.View) { continue }
        foreach ($col in @($lv.View.Columns)) {
            if (-not $col -or -not ($col.Header -is [string])) { continue }
            if (-not $sync.ContainsKey('I18nGridOriginals')) { $sync.I18nGridOriginals = @{} }
            $gridOrig = $sync.I18nGridOriginals
            if (-not $gridOrig.ContainsKey($col)) { $gridOrig[$col] = $col.Header }
            $orig = $gridOrig[$col]
            $target = if ($isEnglish) { $orig } elseif ($orig -and $overrides.ContainsKey($orig)) { $overrides[$orig] } else { $orig }
            if ($col.Header -cne $target) { $col.Header = $target }
        }
    }

    # ---- NavigationView menu items: CLR IList, NOT logical-tree children ----
    # LogicalTreeHelper does not expose them (offline probe: NavigationViewItem reached=0),
    # so the walk above misses Install/Tweaks/Config/... entirely. Translate explicitly,
    # snapshotting English once so switching back restores the exact source strings.
    $nav = $null
    if ($sync.ContainsKey('NavView') -and $sync.NavView) {
        $nav = $sync.NavView
    } elseif ($sync.Form) {
        try { $nav = $sync.Form.FindName('WPFNavView') } catch { }
    }
    if ($nav) {
        if (-not $sync.ContainsKey('I18nNavOriginals')) {
            $navOrig = @{}
            foreach ($ni in @($nav.MenuItems)) {
                if ($ni -and $ni.Content -is [string]) { $navOrig[$ni] = $ni.Content }
            }
            $sync.I18nNavOriginals = $navOrig
        }
        foreach ($ni in @($nav.MenuItems)) {
            if (-not $ni) { continue }
            $orig = $sync.I18nNavOriginals[$ni]
            if ($null -eq $orig) { continue }
            $target = if ($isEnglish) { $orig } elseif ($orig -and $overrides.ContainsKey($orig)) { $overrides[$orig] } else { $orig }
            if ($ni.Content -cne $target) { $ni.Content = $target }
        }
    }

    # ---- Tab navigation buttons: styled TextBlocks (Underline) rebuilt explicitly ----
    $tabTitles = @{
        'WPFTab1BT' = 'Install'
        'WPFTab2BT' = 'Tweaks'
        'WPFTab3BT' = 'Config'
        'WPFTab4BT' = 'Updates'
        'WPFTab5BT' = 'Win11 Creator'
    }
    foreach ($entry in $tabTitles.GetEnumerator()) {
        $btn = $sync.Form.FindName($entry.Key)
        if (-not $btn) { continue }
        $englishTitle = $entry.Value
        $title = if ($isEnglish -or -not $overrides -or -not $overrides.ContainsKey($englishTitle)) { $englishTitle } else { $overrides[$englishTitle] }
        $tb = New-Object Windows.Controls.TextBlock
        $tb.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "TabButtonFontSize")
        if ($lang -eq 'en') {
            # Restore the underlined-first-letter layout for English
            $tb.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
            $u = New-Object Windows.Documents.Underline
            $u.Inlines.Add($englishTitle.Substring(0, 1))
            $tb.Inlines.Add($u)
            $tb.Inlines.Add($englishTitle.Substring(1))
        } else {
            $tb.Text = $title
            # Keep the per-tab accent colour the XAML gave the inner TextBlock
            $old = $btn.Content
            if ($old -is [Windows.Controls.TextBlock]) {
                $tb.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
            }
        }
        $btn.Content = $tb
    }

    Write-WinUtilLog -Component "UI" -Message "UI language set to '$lang'."

    # Force every config-driven tab to rebuild on its next visit (and rebuild the active one
    # right away) so dynamic areas pick up the new language. Rebuild uses the English configs
    # which Set-WinUtilLanguage has already translated, so both directions work.
    $sync.InitializedTabs = @{}
    if ($sync.currentTab) {
        try { Initialize-WinUtilTabContent -TabName $sync.currentTab } catch {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Rebuilding '$($sync.currentTab)' after a language switch failed: $($_.Exception.Message)"
        }
    }

    # The Selected Apps counter was written in the previous language
    try { Reset-WPFCheckBoxes } catch { }
}

function Test-WinUtilConfigKey {
    <#
    .SYNOPSIS
        Tests whether $sync.configs holds an entry, regardless of collection type.

    .DESCRIPTION
        $sync.configs is a Hashtable, but individual configs may arrive as
        PSCustomObject depending on how they were loaded. PSObject.Properties on a
        Hashtable only exposes adapter properties (Keys/Count/...), never the stored
        keys, so membership must be tested through the dictionary interface with a
        PSCustomObject fallback.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Config -is [System.Collections.IDictionary]) {
        return $Config.ContainsKey($Key)
    }
    return ($Config.PSObject.Properties.Name -contains $Key)
}

function Get-WinUtilText {
    <#
    .SYNOPSIS
        Translates a single English string using the active language overrides.

    .DESCRIPTION
        Helper for code-built UI (dialogs, popups, dynamic labels). Returns the
        original text when no override table is active or the key is missing, so
        callers never need a fallback branch.

        When English is active after a language switch, the reverse map restores
        strings that were built in the previous language.

    .PARAMETER text
        The English source string exactly as authored.
    #>
    param([string]$text)

    if ($text -and $sync.LangOverrides -and $sync.LangOverrides.ContainsKey($text)) {
        return $sync.LangOverrides[$text]
    }
    if ($text -and $sync.LangReverse -and $sync.LangReverse.ContainsKey($text)) {
        return $sync.LangReverse[$text]
    }
    return $text
}

function Get-WinUtilStatusText {
    <#
    .SYNOPSIS
        Translates a job status string, keeping any dynamic tail (names, counters).

    .DESCRIPTION
        Statuses are built as "Installing $program ($index/$total)", so an exact key match
        is tried first and a longest-prefix match second. Prefix keys are those ending in a
        space or an open parenthesis, collected once per language switch.
    #>
    param([string]$text)

    if (-not $text -or -not $sync.LangOverrides) { return $text }
    $ov = $sync.LangOverrides

    if ($ov.ContainsKey($text)) { return $ov[$text] }

    $best = $null
    foreach ($key in $sync.I18nStatusPrefixKeys) {
        if ($text.StartsWith($key, [System.StringComparison]::Ordinal) -and
            (-not $best -or $key.Length -gt $best.Length)) {
            $best = $key
        }
    }
    if ($best) { return $ov[$best] + $text.Substring($best.Length) }
    return $text
}
