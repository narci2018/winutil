// WinUtil 一键启动器(v2:自提权架构,全程零控制台窗口)
//
// 设计目标:双击 exe → 自动定位仓库 → 确保 winutil.ps1 已编译 → UAC 提权 → 启动 GUI。
// 刻意不内嵌脚本正文:exe 只做"找脚本 + 拉起",避免 ps2exe 类打包触发的杀软误报,
// 脚本保持可审计,git pull 更新后无需重新打包 exe。
//
// v2 关键变化:UAC 的提权目标是本 exe(/target:winexe,从不拥有控制台),
// UAC 弹窗显示 "WinUtil" 而非 "Windows PowerShell";提权后的副本用
// CreateNoWindow + CREATE_NO_WINDOW 启动 PowerShell,全程无任何终端窗口。
//
// 查找顺序:exe 所在目录 → 上级目录 → 再上级(最多 4 层),命中 winutil.ps1 或 Compile.ps1 即视为仓库根。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;

internal static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    private const uint MB_ICONERROR = 0x00000010;

    private static void Fail(string message)
    {
        MessageBoxW(IntPtr.Zero, message, "WinUtil 启动器", MB_ICONERROR);
    }

    private static bool IsElevated()
    {
        var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            // 第一步:未提权时,提权本 exe 自身(winexe 无控制台,UAC 显示 "WinUtil")
            if (!IsElevated())
            {
                string exePath = Assembly.GetExecutingAssembly().Location;
                var psi = new ProcessStartInfo
                {
                    FileName = exePath,
                    UseShellExecute = true,
                    Verb = "runas",
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                try
                {
                    Process.Start(psi);
                    return 0; // 提权副本接手,本实例退出
                }
                catch
                {
                    // UAC 被拒绝:安静退出,不弹错误框打扰
                    return 1;
                }
            }

            // 第二步:已提权,定位仓库
            string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string root = FindRepoRoot(exeDir);
            if (root == null)
            {
                Fail("找不到 WinUtil 仓库。\n\n请把 WinUtil.exe 放在 winutil 仓库根目录或其 dist 子目录下。");
                return 1;
            }

            string script = Path.Combine(root, "winutil.ps1");
            if (!File.Exists(script))
            {
                string compile = Path.Combine(root, "Compile.ps1");
                if (!File.Exists(compile))
                {
                    Fail("未找到 winutil.ps1,也没有 Compile.ps1,无法自动构建。");
                    return 1;
                }

                // 首次点击:静默编译(约 10-20 秒),完成后再启动
                var cp = Process.Start(new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + compile + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = root
                });
                cp.WaitForExit();
                if (cp.ExitCode != 0 || !File.Exists(script))
                {
                    Fail("自动编译失败(退出码 " + cp.ExitCode + ")。\n请在仓库目录手动运行 Compile.ps1 后重试。");
                    return 1;
                }
            }

            // 第三步:无窗口启动 GUI。CreateNoWindow = 终端窗口从诞生起就不存在,
            // 不存在"先闪现再隐藏"的窗口期;-WindowStyle Hidden 是第二道保险,
            // start.ps1 内部还有自隐藏兜底(第三道)。
            var gui = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = root
            };
            Process.Start(gui);
            return 0;
        }
        catch (Exception ex)
        {
            Fail("启动失败:" + ex.Message);
            return 1;
        }
    }

    private static string FindRepoRoot(string start)
    {
        string dir = start;
        for (int i = 0; i < 4 && !string.IsNullOrEmpty(dir); i++)
        {
            if (File.Exists(Path.Combine(dir, "winutil.ps1")) || File.Exists(Path.Combine(dir, "Compile.ps1")))
            {
                return dir;
            }
            dir = Path.GetDirectoryName(dir);
        }
        return null;
    }
}
