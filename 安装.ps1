$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$exe = Join-Path $dir "自启动管家.exe"
$vbs = Join-Path $dir "启动.vbs"
$icon = if (Test-Path $exe) { $exe } else { Join-Path $dir "assets\app.ico" }

function New-Lnk($Path, $Target, $Args, $WorkDir, $IconPath, $Desc) {
  $sh = New-Object -ComObject WScript.Shell
  $s = $sh.CreateShortcut($Path)
  $s.TargetPath = $Target
  if ($Args) { $s.Arguments = $Args }
  $s.WorkingDirectory = $WorkDir
  if ($IconPath -and (Test-Path $IconPath)) { $s.IconLocation = $IconPath + ",0" }
  $s.Description = $Desc
  $s.Save()
}

if (Test-Path $exe) { $target = $exe; $args = "" }
elseif (Test-Path $vbs) { $target = "C:\Windows\System32\wscript.exe"; $args = "`"$vbs`"" }
else { Write-Host "找不到 自启动管家.exe 或 启动.vbs，无法安装。" -ForegroundColor Red; exit 1 }

$desktop = [Environment]::GetFolderPath("Desktop")
$programs = [Environment]::GetFolderPath("Programs")
$lnk1 = Join-Path $desktop "自启动管家.lnk"
$lnk2 = Join-Path $programs "自启动管家.lnk"
New-Lnk $lnk1 $target $args $dir $icon "开机自启动管理 · 自动同步应用安装与卸载"
New-Lnk $lnk2 $target $args $dir $icon "开机自启动管理 · 自动同步应用安装与卸载"
Write-Host ""
Write-Host "已安装：" -ForegroundColor Green
Write-Host ("  桌面快捷方式  " + $lnk1)
Write-Host ("  开始菜单      " + $lnk2)
Write-Host ("  启动目标      " + $target)
Write-Host ""
Write-Host "提示：首次启动如果弹出蓝色 SmartScreen 提示，点「更多信息」→「仍要运行」即可（本程序为本机自行编译，没有数字签名）。" -ForegroundColor Yellow
