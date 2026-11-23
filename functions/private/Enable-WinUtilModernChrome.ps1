function Enable-WinUtilModernChrome {
    <#
    .SYNOPSIS
        Applies modern window chrome: rounded corners, dark-mode frame, Mica backdrop.

    .DESCRIPTION
        Uses DWM system backdrops (Windows 11 22H2+) so the window gets real system-level
        Mica/acrylic material with rounded corners and a dark frame that follows the theme.

        Also strips the WindowChrome that ModernWpf's merged dictionaries impose on the
        window: their implicit Window style sets GlassFrameThickness=-1 / CaptionHeight=32,
        whose WindowChromeWorker calls DwmExtendFrameIntoClientArea(-1) at SourceInitialized.
        DWM then paints a legacy caption strip (Window.Title + native min/max/close) over the
        client area - the doubled titlebar. A local DP value outranks the implicit style, and
        a zero-margin DWM frame reset undoes the extension already applied by the worker.
    #>
    param([bool]$DarkMode = $true)

    $handle = $null
    try { $handle = [Windows.Interop.WindowInteropHelper]::new($sync.Form).Handle } catch { }
    if (-not $handle -or $handle -eq [IntPtr]::Zero) { return }

    if (-not ('WinUtil.ModernChrome' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace WinUtil {
    public static class ModernChrome {
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
        [StructLayout(LayoutKind.Sequential)]
        public struct Margins { public int Left, Right, Top, Bottom; }

        // DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWA_SYSTEMBACKDROP_TYPE
        public const int DarkMode = 20;
        public const int CornerPreference = 33;
        public const int SystemBackdrop = 38;

        public const int CornerDefault = 0;      // let the system decide
        public const int CornerRound = 2;
        public const int BackdropAuto = 0;       // none
        public const int BackdropMica = 2;       // Mica
        public const int BackdropAcrylic = 3;    // Acrylic
        public const int BackdropMicaAlt = 4;    // Mica Alt (stronger tint)

        // WS_CAPTION is read for diagnostics only.
        public const int GWL_STYLE = -16;
        public const int WS_CAPTION = 0x00C00000;
    }
}
"@
    }

    try {
        # --- Root cause of the doubled titlebar (real-run chrome diag) ---
        # The real window reported: WindowStyle=None, WS_CAPTION absent, topNonClient=0px,
        # yet WindowChrome.GetWindowChrome() = GlassFrameThickness=-1 / CaptionHeight=32.
        # That object comes from ModernWpf's merged ThemeResources/XamlControlsResources
        # (an implicit Window style) - NOT from our XAML. Its WindowChromeWorker extends the
        # DWM frame across the whole window (DwmExtendFrameIntoClientArea(-1)) at
        # SourceInitialized, and DWM paints a legacy caption strip (title text + native
        # min/max/close) on top of the client area regardless of WS_CAPTION.
        # Removing our own XAML WindowChrome block only let the implicit one win; deleting
        # our own DWM(-1) call never touched this one. Hence four rounds of no progress.
        #
        # Fix, in dependency-property precedence order:
        #  1. Set a LOCAL WindowChrome value (glass=0, capH=0, aero=false). A local value
        #     outranks every implicit-style setter / theme-time assignment, so the worker
        #     stops imposing a 32px caption region and never extends the frame again.
        #  2. Reset the already-extended DWM frame with ZERO margins (the -1 extension is
        #     a persistent DWM state that survives the worker detaching). Zero margins are
        #     the opposite of -1: they remove the sheet of glass, they do not create one.
        # Win11 22H2+ Mica needs only DWMWA_SYSTEMBACKDROP_TYPE; it does not need frame
        # extension (that was a Windows 10 Acrylic-era trick).
        $cleanChrome = [Windows.Shell.WindowChrome]::new()
        $cleanChrome.CaptionHeight = 0
        $cleanChrome.GlassFrameThickness = [Windows.Thickness]::new(0)
        $cleanChrome.ResizeBorderThickness = [Windows.Thickness]::new(4)
        $cleanChrome.UseAeroCaptionButtons = $false
        [Windows.Shell.WindowChrome]::SetWindowChrome($sync.Form, $cleanChrome)
        $zeroFrame = New-Object 'WinUtil.ModernChrome+Margins'
        [void][WinUtil.ModernChrome]::DwmExtendFrameIntoClientArea($handle, [ref]$zeroFrame)

        # Dark frame following the theme
        $dark = if ($DarkMode) { 1 } else { 0 }
        [void][WinUtil.ModernChrome]::DwmSetWindowAttribute($handle, [WinUtil.ModernChrome]::DarkMode, [ref]$dark, 4)

        # System rounded corners
        $round = [WinUtil.ModernChrome]::CornerRound
        [void][WinUtil.ModernChrome]::DwmSetWindowAttribute($handle, [WinUtil.ModernChrome]::CornerPreference, [ref]$round, 4)

        # Mica backdrop (independent of the frame extension above)
        if ($sync.MicaBackground) {
            $mica = [WinUtil.ModernChrome]::BackdropMica
            [void][WinUtil.ModernChrome]::DwmSetWindowAttribute($handle, [WinUtil.ModernChrome]::SystemBackdrop, [ref]$mica, 4)
        }
        else {
            # Opaque theme: clear the backdrop so nothing bleeds through
            $none = [WinUtil.ModernChrome]::BackdropAuto
            [void][WinUtil.ModernChrome]::DwmSetWindowAttribute($handle, [WinUtil.ModernChrome]::SystemBackdrop, [ref]$none, 4)
        }

        $finalStyle = [WinUtil.ModernChrome]::GetWindowLong($handle, [WinUtil.ModernChrome]::GWL_STYLE)
        $finalChrome = [Windows.Shell.WindowChrome]::GetWindowChrome($sync.Form)
        $glassNow = if ($finalChrome) { $finalChrome.GlassFrameThickness.ToString() } else { 'null' }
        $capNow = if ($finalChrome) { $finalChrome.CaptionHeight } else { 'n/a' }
        Write-WinUtilLog -Component "UI" -Message "Modern window chrome applied (Mica: $([bool]$sync.MicaBackground), dark frame: $DarkMode, WS_CAPTION absent: $(($finalStyle -band [WinUtil.ModernChrome]::WS_CAPTION) -eq 0), WindowChrome glass=$glassNow capH=$capNow, DWM frame reset to 0)."
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Modern chrome unavailable on this system: $($_.Exception.Message)"
    }
}
