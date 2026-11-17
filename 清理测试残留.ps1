#Requires -Version 5.1
# 清理测试残留：删除 Run\LenovoDisabled 下以 Sm 开头的测试值（需管理员）
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '需要管理员权限，正在申请提权…' -ForegroundColor Yellow
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"') -Verb runas
  } catch { Write-Host '提权被取消。' -ForegroundColor Red }
  exit
}
$targets = @(
  @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run\LenovoDisabled' },
  @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run\LenovoDisabled' }
)
$total = 0; $ok = 0
foreach ($t in $targets) {
  $root = if ($t.Hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
  $k = $root.OpenSubKey($t.Path, $true)
  if (-not $k) { continue }
  foreach ($n in @($k.GetValueNames() | Where-Object { $_ -like 'Sm*' })) {
    $total++
    try { $k.DeleteValue($n, $true); $ok++; Write-Host ('已删除 ' + $t.Hive + ' \ ' + $n) -ForegroundColor Green }
    catch { Write-Host ('删除失败 ' + $n + ' -> ' + $_.Exception.Message) -ForegroundColor Red }
  }
  $k.Close()
}
Write-Host ''
Write-Host ("共发现 $total 个测试残留，成功删除 $ok 个。") -ForegroundColor Cyan
if ($ok -lt $total) {
  Write-Host '仍有残留：请打开「联想电脑管家 → 启动项管理 → 拦截记录」手动清除。' -ForegroundColor Yellow
} else {
  Write-Host '清理完成。可以把 state\config.json 里的 ignoreNames 改回 []。' -ForegroundColor Green
}
Write-Host ''
Read-Host '按回车关闭'
