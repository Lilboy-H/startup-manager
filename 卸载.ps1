$ErrorActionPreference = "SilentlyContinue"
$desktop = [Environment]::GetFolderPath("Desktop")
$programs = [Environment]::GetFolderPath("Programs")
$startup = [Environment]::GetFolderPath("Startup")
$targets = @(
  (Join-Path $desktop "自启动管家.lnk"),
  (Join-Path $programs "自启动管家.lnk"),
  (Join-Path $startup "自启动管家.lnk")
)
foreach ($t in $targets) {
  if (Test-Path $t) { Remove-Item $t -Force; Write-Host ("已删除 " + $t) }
}
Write-Host ""
Write-Host "快捷方式与开机自启项已移除。程序文件和你的配置、备份都保留在原目录。" -ForegroundColor Green
Write-Host "如需彻底删除，直接删除整个 自启动管家 文件夹即可（建议先导出 backup 目录留档）。"
