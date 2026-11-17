using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// 自启动管家 启动器：找到 main.ps1 → 以无窗口方式拉起 powershell；已有窗口则直接唤起（单实例）
class SmLauncher {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);

  [STAThread]
  static int Main(string[] args) {
    string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    string main = Path.Combine(dir, "main.ps1");
    if (!File.Exists(main)) {
      MessageBox.Show("找不到 main.ps1，请把本程序放回安装目录。\n" + main, "自启动管家", MessageBoxButtons.OK, MessageBoxIcon.Error);
      return 1;
    }
    IntPtr exist = FindWindow(null, "自启动管家");
    if (exist != IntPtr.Zero) {
      ShowWindow(exist, 9);
      SetForegroundWindow(exist);
      return 0;
    }
    try {
      ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + main + "\"");
      psi.WorkingDirectory = dir;
      psi.UseShellExecute = true;
      psi.WindowStyle = ProcessWindowStyle.Hidden;
      Process.Start(psi);
    } catch (Exception ex) {
      MessageBox.Show("启动失败：" + ex.Message, "自启动管家", MessageBoxButtons.OK, MessageBoxIcon.Error);
      return 1;
    }
    return 0;
  }
}
