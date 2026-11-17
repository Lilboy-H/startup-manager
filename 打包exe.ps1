# 用系统自带的 C# 编译器打包 自启动管家.exe（无需装任何 SDK）
$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { Write-Host "找不到 csc.exe（.NET Framework 4 未安装）" -ForegroundColor Red; exit 1 }
$out = Join-Path $dir "自启动管家.exe"
$src = Join-Path $dir "src\launcher.cs"
$ico = Join-Path $dir "assets\app.ico"
& $csc /nologo /target:winexe /codepage:65001 /optimize+ ("/win32icon:" + $ico) ("/out:" + $out) $src
if (Test-Path $out) { Write-Host ("已生成 " + $out + "  " + (Get-Item $out).Length + " 字节") -ForegroundColor Green }
else { Write-Host "编译失败" -ForegroundColor Red }
