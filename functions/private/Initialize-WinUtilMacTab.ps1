# Round 14: Change MAC Address tab, modeled on TMAC v6.
# Adapters are read via Get-NetAdapter plus the MSFT_NetAdapter PermanentAddress;
# the adapter InterfaceGuid matches the NetCfgInstanceId of a subkey under the
# network class key, where TMAC (and this tab) write the NetworkAddress value.
# Writing NetworkAddress + restarting the adapter applies the address; deleting
# the value + restarting restores the original. Scans and every system-changing
# operation run in a job worker. Button clicks go through Invoke-WPFButtonAction's
# prefix routing like every other tab, so no control is double-wired.

# Registry key for one adapter. $null when the adapter has no matching subkey
# (e.g. the Hyper-V Default Switch, whose InterfaceGuid does not appear there).
function Get-WinUtilMacAdapterKey {
    param([string]$InterfaceGuid)
    if (-not $InterfaceGuid) { return $null }
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    $sub = Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).NetCfgInstanceId -eq "{$InterfaceGuid}"
    } | Select-Object -First 1
    if ($sub) { return $sub.PSPath }
    return $null
}

function Get-WinUtilMacAdapters {
    # The job worker calls this; every error path degrades to an empty field.
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    $reg = @{}
    foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.NetCfgInstanceId) { $reg[[string]$p.NetCfgInstanceId] = [pscustomobject]@{ Key = $k.PSPath; Name = $k.PSChildName; NetAddr = [string]$p.NetworkAddress } }
    }

    $cim = @{}
    foreach ($a in @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -ErrorAction SilentlyContinue)) {
        $cim[$a.InterfaceIndex] = $a
    }

    $stats = @{}
    foreach ($s in @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) {
        $stats[$s.Name] = $s
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $guid = [string]$a.InterfaceGuid
        $hit = $reg[$guid]
        if (-not $hit) { $hit = $reg["{$guid}"] }
        $active = [string]$a.MacAddress
        $cimA = $cim[$a.ifIndex]
        $original = if ($cimA -and $cimA.PermanentAddress) { $cimA.PermanentAddress } else { $active }
        # PermanentAddress has no separators (12 hex); normalize both to XX-XX-... for display.
        if ($original -and $original -notmatch '-') { $original = ($original -replace '(.{2})', '$1-').TrimEnd('-') }
        if ($active -and $active -notmatch '-') { $active = ($active -replace '(.{2})', '$1-').TrimEnd('-') }
        $changed = if ($original -and $active -and ($original -replace '[^0-9A-Fa-f]', '') -ne ($active -replace '[^0-9A-Fa-f]', '')) { 'Yes' } else { 'No' }
        $result.Add([pscustomobject]@{
            Id           = $a.Name
            Name         = [string]$a.Name
            Description  = [string]$a.InterfaceDescription
            State        = [string]$a.Status
            Speed        = [string]$a.LinkSpeed
            Mac          = $active
            OriginalMac  = $original
            Changed      = $changed
            HardwareId   = [string]$a.PnPDeviceID
            ConfigId     = if ($hit) { $hit.Name } else { 'NO MATCH' }
            HasRegKey    = [bool]$hit
            RegKey       = if ($hit) { $hit.Key } else { $null }
            NetAddr      = if ($hit) { $hit.NetAddr } else { '' }
            ifIndex      = [int]$a.ifIndex
            InterfaceGuid= $guid
            ReceivedBytes= if ($stats[$a.Name]) { [double]$stats[$a.Name].ReceivedBytes } else { 0 }
            SentBytes    = if ($stats[$a.Name]) { [double]$stats[$a.Name].SentBytes } else { 0 }
        })
    }
    return @($result | Sort-Object Name)
}

function New-WinUtilRandomMac {
    param([switch]$LocalBit)
    $bytes = for ($i = 0; $i -lt 6; $i++) { Get-Random -Minimum 0 -Maximum 256 }
    # Always keep the locally-administered bit set and clear the multicast bit:
    # a first octet of 0x03/0x07 would otherwise be an invalid unicast MAC.
    if ($LocalBit) { $bytes[0] = 0x02 } else { $bytes[0] = ($bytes[0] -bor 0x02) -band 0xFE }
    return (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '-')
}

function Format-WinUtilMacInput {
    param([string]$Text)
    $hex = ([string]$Text) -replace '[^0-9A-Fa-f]', ''
    if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { return $null }
    return (($hex.ToCharArray() | ForEach-Object { $_ }) -join '' -replace '(.{2})', '$1-').TrimEnd('-')
}

function Get-WinUtilMacSelectedItem {
    $list = $sync['WPFMacAdapterList']
    if ($list) { return $list.SelectedItem }
    return $null
}

# The row objects in the list are display clones (State/Changed translated);
# resolve the authoritative English row from the scan cache by Id.
function Get-WinUtilMacSelectedAdapter {
    $sel = Get-WinUtilMacSelectedItem
    if (-not $sel) { return $null }
    foreach ($a in @($sync.MacAdapters)) { if ($a.Id -eq $sel.Id) { return $a } }
    return $sel
}

function Set-WinUtilMacDetails {
    param($Item)
    $empty = $sync['WPFMacDetailEmpty']
    $grid = $sync['WPFMacDetailGrid']
    if (-not $Item) {
        if ($empty) { $empty.Visibility = 'Visible' }
        if ($grid) { $grid.Visibility = 'Collapsed' }
        $traffic = $sync['WPFMacTraffic']
        if ($traffic) { $traffic.Text = (Get-WinUtilText 'Select an adapter to monitor its traffic.') }
        if ($sync.ContainsKey('MacTrafficTimer') -and $sync.MacTrafficTimer) {
            $sync.MacTrafficTimer.Stop()
        }
        return
    }
    if ($empty) { $empty.Visibility = 'Collapsed' }
    if ($grid) { $grid.Visibility = 'Visible' }
    $map = @{
        'WPFMacDDevice'       = 'Description'
        'WPFMacDHardwareId'   = 'HardwareId'
        'WPFMacDConfigId'     = 'ConfigId'
        'WPFMacDTcpIp'        = 'State'
        'WPFMacDOriginalMac'  = 'OriginalMac'
        'WPFMacDActiveMac'    = 'Mac'
    }
    foreach ($entry in $map.GetEnumerator()) {
        $tb = $sync[$entry.Key]
        if (-not $tb) { continue }
        $value = $Item.($entry.Value)
        if ($null -eq $value) { $value = '' }
        if (-not $value -and $entry.Value -in @('OriginalMac', 'Mac')) { $value = Get-WinUtilText 'Not available' }
        $tb.Text = [string]$value
    }
    # Traffic timer: refresh the selected adapter's counters every 2s.
    if (-not $sync.ContainsKey('MacTrafficTimer') -or -not $sync.MacTrafficTimer) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(2)
        $timer.Add_Tick({ Update-WinUtilMacTraffic })
        $sync.MacTrafficTimer = $timer
    }
    $sync.MacTrafficTimer.Stop()
    Update-WinUtilMacTraffic
    $sync.MacTrafficTimer.Start()
}

function Update-WinUtilMacTraffic {
    $traffic = $sync['WPFMacTraffic']
    if (-not $traffic) { return }
    $sel = Get-WinUtilMacSelectedItem
    if (-not $sel) { return }
    $name = $sel.Id
    try {
        $s = Get-NetAdapterStatistics -Name $name -ErrorAction Stop
        $rx = [double]$s.ReceivedBytes
        $tx = [double]$s.SentBytes
        $prev = if ($sync.ContainsKey('MacTrafficPrev') -and $sync.MacTrafficPrev -and $sync.MacTrafficPrev.Id -eq $name) { $sync.MacTrafficPrev } else { $null }
        $rxRate = 0.0; $txRate = 0.0
        if ($prev) {
            $dt = ((Get-Date) - $prev.At).TotalSeconds
            if ($dt -gt 0.2) {
                $rxRate = [Math]::Max(0, ($rx - $prev.Rx) / $dt)
                $txRate = [Math]::Max(0, ($tx - $prev.Tx) / $dt)
            }
        }
        $sync.MacTrafficPrev = @{ Id = $name; Rx = $rx; Tx = $tx; At = (Get-Date) }
        $fmt = { param($v) if ($v -ge 1GB) { '{0:N2} GB' -f ($v / 1GB) } elseif ($v -ge 1MB) { '{0:N2} MB' -f ($v / 1MB) } elseif ($v -ge 1KB) { '{0:N2} KB' -f ($v / 1KB) } else { '{0:N0} B' -f $v } }
        $rateFmt = { param($v) if ($v -ge 1MB) { '{0:N2} MB/s' -f ($v / 1MB) } elseif ($v -ge 1KB) { '{0:N1} KB/s' -f ($v / 1KB) } else { '{0:N0} B/s' -f $v } }
        $traffic.Text = "$(Get-WinUtilText 'Received'): $(& $fmt $rx) ($(& $rateFmt $rxRate))   $(Get-WinUtilText 'Sent'): $(& $fmt $tx) ($(& $rateFmt $txRate))"
    } catch {
        $traffic.Text = (Get-WinUtilText 'Traffic information is not available for this adapter.')
    }
}

function ConvertTo-WinUtilMacDisplayRows {
    param([object[]]$Rows)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $clone = [pscustomobject]@{}
        foreach ($p in $row.PSObject.Properties) { $clone | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        foreach ($field in @('State', 'Changed')) {
            $value = $clone.$field
            if ($value -is [string] -and $value) { $clone.$field = Get-WinUtilText $value }
        }
        # Wintun/tunnel adapters have no burned-in MAC. Fill the empty cells in
        # the display clone only; the data rows keep empty values for comparisons.
        $noMac = Get-WinUtilText 'Not available'
        foreach ($field in @('Mac', 'OriginalMac')) {
            if (-not $clone.$field) { $clone.$field = $noMac }
        }
        $out.Add($clone)
    }
    return @($out)
}

function Update-WinUtilMacRows {
    param([object[]]$Rows)
    $list = $sync['WPFMacAdapterList']
    if (-not $list) { return }
    $list.ItemsSource = @(ConvertTo-WinUtilMacDisplayRows -Rows $Rows)
    $count = $sync['WPFMacStatus']
    $rowCount = @($Rows).Count
    if ($count) {
        $count.Text = "$rowCount $(Get-WinUtilText 'network adapters found; select one to view and change its MAC address')"
    }
    Set-WinUtilMacDetails $null
}

function Start-WinUtilMacScan {
    $loading = $sync['WPFMacLoading']
    if ($loading) { $loading.Visibility = 'Visible'; $loading.Text = (Get-WinUtilText 'Scanning network adapters...') }
    $status = $sync['WPFMacStatus']
    if ($status) { $status.Text = (Get-WinUtilText 'Scanning network adapters in the background...') }
    Start-WinUtilJob -Name "MAC Address Scan" -Description 'Scanning network adapters' -ScriptBlock {
        Step-WinUtilJob -Status 'Reading network adapters...' -Percent 20
        $adapters = @(Get-WinUtilMacAdapters)
        Step-WinUtilJob -Status 'Publishing results...' -Percent 80
        Invoke-WPFUIThread -Async -Parameters @{ Adapters = $adapters } -ScriptBlock {
            param($Adapters)
            $sync.MacAdapters = @($Adapters)
            $sync.MacDataLoaded = $true
            $loading = $sync['WPFMacLoading']
            if ($loading) { $loading.Visibility = 'Collapsed' }
            Update-WinUtilMacRows -Rows $sync.MacAdapters
            Write-WinUtilLog -Level 'DEBUG' -Component 'UI' -Message ("mac scan probe: adapters=$($Adapters.Count)")
        }
        Step-WinUtilJob -Percent 100
    }
}

# Apply a new MAC address (or restore the original by deleting NetworkAddress).
# Runs in the job worker: writes/removes HKLM NetworkAddress, then optionally
# restarts the adapter. AutoRestart comes from the "automatically restart the
# connection" checkbox; Persistent controls whether the override is kept across
# connection resets (non-persistent = revert to the burned-in address after the
# adapter is disabled, matching TMAC's -nm semantics as closely as Windows allows).
function Start-WinUtilMacChange {
    param(
        [Parameter(Mandatory)][string]$AdapterId,
        [string]$MacAddress,
        [switch]$Restore,
        [switch]$Persistent,
        [switch]$AutoRestart
    )
    Start-WinUtilJob -Name "MAC Address Change" -Description 'Applying MAC address change' -ScriptBlock {
        param($AdapterId, $MacAddress, $Restore, $Persistent, $AutoRestart)
        Step-WinUtilJob -Status 'Resolving the adapter registry key...' -Percent 10
        $adapters = @(Get-WinUtilMacAdapters)
        $adapter = @($adapters | Where-Object { $_.Id -eq $AdapterId })[0]
        if (-not $adapter) {
            Step-WinUtilJob -Status "Adapter '$AdapterId' was not found." -Percent 100 -State 'Error'
            return
        }
        if (-not $adapter.HasRegKey) {
            Step-WinUtilJob -Status "No registry configuration key for '$AdapterId'; the MAC address cannot be changed here." -Percent 100 -State 'Error'
            return
        }
        $key = $adapter.RegKey
        try {
            # Capture the pre-change registry state before touching anything.
            $previous = (Get-ItemProperty $key -ErrorAction SilentlyContinue).NetworkAddress
            $hadPrevious = [bool]$previous
            if ($Restore) {
                Step-WinUtilJob -Status 'Deleting the NetworkAddress override...' -Percent 40
                $props = Get-ItemProperty $key -ErrorAction Stop
                if ($props.PSObject.Properties['NetworkAddress']) {
                    Remove-ItemProperty -Path $key -Name 'NetworkAddress' -ErrorAction Stop
                }
            } else {
                $hex = ([string]$MacAddress) -replace '[^0-9A-Fa-f]', ''
                if ($hex -notmatch '^[0-9A-Fa-f]{12}$') {
                    Step-WinUtilJob -Status 'The MAC address must be exactly 12 hexadecimal digits.' -Percent 100 -State 'Error'
                    return
                }
                Step-WinUtilJob -Status 'Writing the NetworkAddress value...' -Percent 40
                New-ItemProperty -Path $key -Name 'NetworkAddress' -Value $hex -PropertyType String -Force -ErrorAction Stop | Out-Null
            }
            # Non-persistent: after the driver has read the override (restart),
            # put the registry back. The running MAC stays changed; the next
            # disable/enable cycle returns to the original (TMAC -nm semantics).
            $doRestart = [bool]$AutoRestart
            if (-not $Restore -and -not $Persistent) { $doRestart = $true }
            if ($doRestart) {
                Step-WinUtilJob -Status 'Restarting the network adapter...' -Percent 70
                Restart-NetAdapter -Name $AdapterId -Confirm:$false -ErrorAction Stop
                if (-not $Restore -and -not $Persistent) {
                    Step-WinUtilJob -Status 'Removing the persistent override...' -Percent 80
                    if ($hadPrevious) {
                        New-ItemProperty -Path $key -Name 'NetworkAddress' -Value $previous -PropertyType String -Force -ErrorAction Stop | Out-Null
                    } else {
                        Remove-ItemProperty -Path $key -Name 'NetworkAddress' -ErrorAction SilentlyContinue
                    }
                }
            } else {
                Step-WinUtilJob -Status 'Override written; disable/enable the adapter to apply it.' -Percent 70
            }
            Step-WinUtilJob -Status 'Refreshing adapter data...' -Percent 90
            $adapters2 = @(Get-WinUtilMacAdapters)
            Invoke-WPFUIThread -Async -Parameters @{ Adapters = $adapters2; Id = $AdapterId; Persistent = $Persistent; AutoRestart = $AutoRestart } -ScriptBlock {
                param($Adapters, $Id, $Persistent, $AutoRestart)
                $sync.MacAdapters = @($Adapters)
                Update-WinUtilMacRows -Rows $sync.MacAdapters
                $sel = $sync['WPFMacAdapterList']
                if ($sel) {
                    foreach ($it in @($sel.ItemsSource)) { if ($it.Id -eq $Id) { $sel.SelectedItem = $it; break } }
                }
                $st = $sync['WPFMacStatus']
                if ($st) {
                    $persistNote = if ($Persistent) { (Get-WinUtilText 'The new MAC is persistent.') } else { (Get-WinUtilText 'The new MAC is not persistent; it will revert when the adapter is disabled.') }
                    $restartNote = if ($AutoRestart) { (Get-WinUtilText 'The adapter was restarted.') } else { (Get-WinUtilText 'Restart the connection (disable/enable) to apply the change.') }
                    $st.Text = "$persistNote $restartNote"
                }
                Write-WinUtilLog -Level 'DEBUG' -Component 'UI' -Message ("mac change probe: reselect=[$Id] adapters=$($Adapters.Count) persistent=[$Persistent] autoRestart=[$AutoRestart]")
            }
            Step-WinUtilJob -Percent 100
        } catch {
            Step-WinUtilJob -Status $_.Exception.Message -Percent 100 -State 'Error'
        }
    } -Parameters @{
        AdapterId = $AdapterId
        MacAddress = $MacAddress
        Restore = [bool]$Restore
        Persistent = [bool]$Persistent
        AutoRestart = [bool]$AutoRestart
    }
}

function Initialize-WinUtilMacTab {
    if ($sync.MacTabWired) { return }
    $sync.MacTabWired = $true
    $sync.MacAdapters = @()
    $sync.MacDataLoaded = $false

    # Non-button events only; buttons route through Invoke-WPFButtonAction.
    $sync['WPFMacAdapterList'].Add_SelectionChanged({ Set-WinUtilMacDetails $args[0].SelectedItem })
    $sync['WPFMacInput'].Add_TextChanged({
        $input = $sync['WPFMacInput']
        if ($input) {
            $hex = [string]$input.Text -replace '[^0-9A-Fa-f]', ''
            if ($hex.Length -gt 12) {
                $hex = $hex.Substring(0, 12)
                # Reformat with separators as the user types (caret moves to end; acceptable).
                $caret = $input.CaretIndex
                $formatted = ($hex -replace '(.{2})', '$1-').TrimEnd('-')
                if ($input.Text -cne $formatted) {
                    $input.Text = $formatted
                    try { $input.CaretIndex = [Math]::Min($caret, $formatted.Length) } catch { }
                }
        }
        }
    })

    Start-WinUtilMacScan
}

function Invoke-WinUtilMacButton {
    param([string]$Button)
    switch ($Button) {
        'WPFMacRefresh'   { Start-WinUtilMacScan; return }
        'WPFMacRandom'    {
            $input = $sync['WPFMacInput']
            if ($input) {
                $local = $false
                $cb = $sync['WPFMacLocalBit']
                if ($cb) { $local = [bool]$cb.IsChecked }
                $input.Text = New-WinUtilRandomMac -LocalBit:$local
            }
            return
        }
        'WPFMacChange'    {
            $sel = Get-WinUtilMacSelectedAdapter
            if (-not $sel) {
                Show-WinUtilMessage -Message (Get-WinUtilText 'Select a network adapter first.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
                return
            }
            $input = $sync['WPFMacInput']
            $mac = if ($input) { Format-WinUtilMacInput -Text $input.Text } else { $null }
            if (-not $mac) {
                Show-WinUtilMessage -Message (Get-WinUtilText 'Enter a valid MAC address (12 hexadecimal digits, e.g. 00:01:02:03:04:05).') -Title 'WinUtil' -Button 'OK' -Icon 'Warning'
                return
            }
            $current = ($sel.Mac -replace '[^0-9A-Fa-f]', '')
            if (($mac -replace '[^0-9A-Fa-f]', '') -eq $current) {
                Show-WinUtilMessage -Message (Get-WinUtilText 'The new MAC address equals the active one; nothing to change.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
                return
            }
            # Danger: changing the MAC can restart the adapter and drop the
            # connection (RDP/SSH sessions included). Confirm before touching HKLM.
            $autoRestart = $true
            $arcb = $sync['WPFMacAutoRestart']
            if ($arcb) { $autoRestart = [bool]$arcb.IsChecked }
            $persist = $true
            $pcb = $sync['WPFMacPersist']
            if ($pcb) { $persist = [bool]$pcb.IsChecked }
            $riskNote = if ($autoRestart -or -not $persist) { (Get-WinUtilText 'will restart the adapter and may briefly interrupt the network. Continue?') } else { (Get-WinUtilText 'will write the registry value; disable/enable the adapter to apply it. Continue?') }
            $confirm = Show-WinUtilMessage -Message "$(Get-WinUtilText 'Changing the MAC address of') '$($sel.Name)' $riskNote" -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning'
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            Start-WinUtilMacChange -AdapterId $sel.Id -MacAddress $mac -Persistent:$persist -AutoRestart:$autoRestart
            return
        }
        'WPFMacRestore'   {
            $sel = Get-WinUtilMacSelectedAdapter
            if (-not $sel) {
                Show-WinUtilMessage -Message (Get-WinUtilText 'Select a network adapter first.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
                return
            }
            if (-not $sel.HasRegKey) {
                Show-WinUtilMessage -Message (Get-WinUtilText 'No registry configuration key exists for this adapter; there is nothing to restore.') -Title 'WinUtil' -Button 'OK' -Icon 'Warning'
                return
            }
            if (($sel.NetAddr -replace '[^0-9A-Fa-f]', '') -eq '') {
                Show-WinUtilMessage -Message (Get-WinUtilText 'This adapter has no MAC address override; the original MAC is already active.') -Title 'WinUtil' -Button 'OK' -Icon 'Information'
                return
            }
            $autoRestart = $true
            $arcb = $sync['WPFMacAutoRestart']
            if ($arcb) { $autoRestart = [bool]$arcb.IsChecked }
            $riskNote = if ($autoRestart) { (Get-WinUtilText 'will restart the adapter and may briefly interrupt the network. Continue?') } else { (Get-WinUtilText 'will write the registry value; disable/enable the adapter to apply it. Continue?') }
            $confirm = Show-WinUtilMessage -Message "$(Get-WinUtilText 'Restoring the original MAC address of') '$($sel.Name)' $riskNote" -Title 'WinUtil' -Button 'YesNo' -Icon 'Warning'
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            Start-WinUtilMacChange -AdapterId $sel.Id -Restore -AutoRestart:$autoRestart
            return
        }
    }
}
