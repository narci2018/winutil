<#
.SYNOPSIS
    构建 WinUtil 一键启动器 exe（黑科技风图标 + 原生小体积启动器）。

.DESCRIPTION
    用 .NET Framework 自带的 csc.exe 编译 tools/launcher/WinUtilLauncher.cs 到 dist/WinUtil.exe，
    并程序化生成深底霓虹青 "W" 图标（无需外部素材）。产物被根 .gitignore 的 dist/ 规则忽略。

.PARAMETER Shortcut
    同时尝试在桌面创建快捷方式（失败不影响构建）。

.EXAMPLE
    .\build-launcher.ps1
    .\build-launcher.ps1 -Shortcut
#>
param(
    [switch]$Shortcut
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$source = Join-Path $PSScriptRoot 'WinUtilLauncher.cs'
$outDir = Join-Path $repoRoot 'dist'
$exePath = Join-Path $outDir 'WinUtil.exe'
$icoPath = Join-Path $outDir 'winutil.ico'

if (-not (Test-Path $source)) { throw "找不到启动器源码: $source" }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# ---- 1. 生成图标：深底圆角 + 霓虹青 W ----
Add-Type -AssemblyName System.Drawing
$size = 32
$bmp = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 8, 12, 18))
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$r = 7
$path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
$path.AddArc($size - $r * 2, 0, $r * 2, $r * 2, 270, 90)
$path.AddArc($size - $r * 2, $size - $r * 2, $r * 2, $r * 2, 0, 90)
$path.AddArc(0, $size - $r * 2, $r * 2, $r * 2, 90, 90)
$path.CloseFigure()
$g.FillPath($bg, $path)

$neon = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0, 229, 255))
$font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$g.DrawString('W', $font, $neon, (New-Object System.Drawing.RectangleF 0, 0, $size, $size), $fmt)

$hIcon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)
$fs = [System.IO.File]::Create($icoPath)
$icon.Save($fs)
$fs.Close()
$icon.Dispose(); $font.Dispose(); $neon.Dispose(); $bg.Dispose(); $g.Dispose(); $bmp.Dispose()

# ---- 2. 编译 ----
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) { throw '找不到 .NET Framework 4.x 的 csc.exe，无法编译启动器。' }

& $csc /nologo /codepage:65001 /target:winexe /platform:anycpu /optimize+ "/win32icon:$icoPath" "/out:$exePath" $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exePath)) { throw "csc 编译失败（退出码 $LASTEXITCODE）。" }

Write-Host "启动器已生成: $exePath" -ForegroundColor Green
Write-Host ("大小: {0:N0} 字节" -f (Get-Item $exePath).Length)

# ---- 3. 可选：桌面快捷方式 ----
if ($Shortcut) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'WinUtil.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath = $exePath
        $lnk.WorkingDirectory = $repoRoot
        $lnk.IconLocation = $exePath
        $lnk.Description = 'WinUtil 一键启动'
        $lnk.Save()
        Write-Host "桌面快捷方式已创建: $lnkPath" -ForegroundColor Green
    } catch {
        Write-Warning "桌面快捷方式创建失败（不影响使用）: $($_.Exception.Message)"
    }
}
