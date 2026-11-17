#Requires -Version 5.1
<#  main.ps1 - 自启动管家 界面主程序  #>
$ErrorActionPreference = 'Stop'

# ---------- 原生函数：优先加载预编译 DLL（避免 Add-Type 依赖 %TEMP% 编译，受限环境会失败） ----------
$nativeDll = Join-Path $PSScriptRoot 'lib\SmNative.dll'
if (-not ('SmDpi' -as [type])) {
  try {
    if (Test-Path -LiteralPath $nativeDll) { $null = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($nativeDll)) }
  } catch {}
}

# ---------- DPI 感知（必须在任何窗口创建前设置，否则 150% 缩放下界面被裁切） ----------
try {
  if (-not ('SmDpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SmDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr ctx);
}
'@
  }
  $ctx = [IntPtr](-4)   # PER_MONITOR_AWARE_V2
  $ok = [SmDpi]::SetProcessDpiAwarenessContext($ctx)
  if ($ok -eq [IntPtr]::Zero) { [SmDpi]::SetProcessDPIAware() | Out-Null }
} catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$root = $PSScriptRoot
. (Join-Path $root 'lib\Core.ps1')
. (Join-Path $root 'lib\Advice.ps1')

# ---------- 深色标题栏 ----------
if (-not ('SmNative' -as [type])) {
  try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SmNative {
  [DllImport("dwmapi.dll")]
  public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
  } catch {}
}

$cfg = Get-SmConfig
$isAdmin = Test-SmAdmin

# ---------- 加载界面 ----------
$xamlPath = Join-Path $root 'ui\App.xaml'
if (-not (Test-Path $xamlPath)) { throw "缺少界面文件: $xamlPath" }
$xaml = Get-Content $xamlPath -Raw -Encoding UTF8
$win = [Windows.Markup.XamlReader]::Parse($xaml)

# 窗口图标（标题栏 / 任务栏 / Alt+Tab 都用它）
$icoPath = Join-Path $root 'assets\app.ico'
if (Test-Path -LiteralPath $icoPath) {
  try { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]('file:///' + ($icoPath -replace '\\', '/'))) } catch {}
}

$ui = @{}
foreach ($n in @('SearchBox','SearchHint','NavList','ItemsList','ChangesList','ChangesPanel','EmptyHint',
                 'ListHeader','ChangesHeader','StatusText','StatusDot','SubTitle','AdminBadge','AdminText',
                 'ElevateBtn','RefreshBtn','AutoDisableBox','WatcherText',
                 'DetailOverlay','DetailCard','DetailTitle','DetailSub','VerdictBadge','VerdictText',
                 'DetailCloseBtn','PurposeText','WhyText','DisText','KeepText','FactsPanel',
                 'DetailHint','DetailToggleBtn',
                 'AdviceBtn','AdvicePanel','AdviceList','AdviceHeader','AdviceSummary','AdviceEmpty',
                 'AdvFilterAll','AdvFilterRec','AdvFilterFree','AdvFilterCau','AdvFilterKeep',
                 'AdviceScanBtn','StatTotal','StatOn','StatOff','StatSugg','DetailCard',
                 'SelfStartBox','SettingsPanel','ThemeBtn0','ThemeBtn1','ThemeBtn2','ThemeBtn3',
                 'WatchBtn0','WatchBtn1','WatchBtn2','WatchBtn3','SetSelfStartBox','SetAutoDisableBox',
                 'SetShowSystemBox','IgnoreBox','IgnoreSaveBtn','IgnoreHint','AboutVersion','AboutPath',
                 'AboutData','AboutState','OpenDataBtn','OpenAppBtn','AboutDocBtn','DetailOpenBtn',
                 'DetailHeadBg')) {
  $ui[$n] = $win.FindName($n)
}

# ---------- 分类 ----------
$script:NavDefs = @(
  @{ Key='all';     Label='全部启动项';   Hex='#6EA8FE' }
  @{ Key='user';    Label='用户登录项';   Hex='#35D399' }
  @{ Key='machine'; Label='系统级启动项'; Hex='#B48EF0' }
  @{ Key='task';    Label='计划任务';     Hex='#F0B45B' }
  @{ Key='uwp';     Label='商店应用';     Hex='#35D399' }
  @{ Key='service'; Label='自动服务';     Hex='#EAEBEB' }
  @{ Key='quar';    Label='被拦截项';     Hex='#F0716E' }
  @{ Key='advice';  Label='推荐清单';     Hex='#5B8DEF' }
  @{ Key='changes'; Label='变更记录';     Hex='#DDDDDD' }
  @{ Key='settings'; Label='设置';      Hex='#8A8B8C' }
)
$script:CurrentNav = 'all'
$script:AllItems = @()
$script:ViewVms = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:ChangeVms = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:AdviceRows = @()
$script:AdvVerdictFilter = 'all'
$script:AdvReady = $false
$script:ScanPs = $null
$script:ScanHandle = $null
$script:BootMs = [Diagnostics.Stopwatch]::StartNew()
$script:ScanSw = [Diagnostics.Stopwatch]::StartNew()

# ---------- 主题：运行期只改 Brush 颜色，绝不重写界面文件 ----------
$script:Themes = [ordered]@{
  '纯黑' = @{ Bg='#0A0A0A'; Panel='#141414'; PanelHi='#191919'; Card='#151515'; CardHi='#1E1E1E'; Stroke='#262626'; StrokeHi='#333333'; Text='#F2F3F4'; Sub='#DCDDDD'; Dim='#8E8F90'; WinTop='#0D0D0D'; WinBottom='#080808' }
  '石墨' = @{ Bg='#161617'; Panel='#282829'; PanelHi='#303031'; Card='#2D2E2E'; CardHi='#3A3B3B'; Stroke='#464647'; StrokeHi='#5F6061'; Text='#EAF0FA'; Sub='#EAEBEB'; Dim='#AEAFB0'; WinTop='#19191A'; WinBottom='#151515' }
  '暖棕' = @{ Bg='#14100D'; Panel='#201A15'; PanelHi='#26201A'; Card='#241D18'; CardHi='#2E2721'; Stroke='#3A2F25'; StrokeHi='#4A3C30'; Text='#F5EFE8'; Sub='#D8CCC0'; Dim='#9C8E80'; WinTop='#181310'; WinBottom='#110E0B' }
  '原蓝' = @{ Bg='#0A0D13'; Panel='#121722'; PanelHi='#161C28'; Card='#151B26'; CardHi='#1B2231'; Stroke='#222A39'; StrokeHi='#2F3A4D'; Text='#EAF0FA'; Sub='#C7D2E3'; Dim='#94A1B6'; WinTop='#0B0F16'; WinBottom='#090C12' }
}
$script:ThemeName = '石墨'

function New-LiveBrush {
  param([string]$Hex)
  return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)))
}

function Set-ThemeBrush {
  param([string]$Key, [string]$Hex)
  try {
    $col = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $b = $win.Resources[$Key]
    if ($b -is [System.Windows.Media.SolidColorBrush] -and -not $b.IsFrozen) { $b.Color = $col }
    else { $win.Resources[$Key] = New-LiveBrush $Hex }
  } catch {}
}

function Update-ThemeBtns {
  foreach ($b in @($ui.ThemeBtn0, $ui.ThemeBtn1, $ui.ThemeBtn2, $ui.ThemeBtn3)) {
    if (-not $b) { continue }
    if ([string]$b.Tag -eq $script:ThemeName) {
      $b.BorderBrush = ConvertTo-Brush '#5B8DEF'
      $b.BorderThickness = New-Object System.Windows.Thickness(1.6)
      $b.Background = ConvertTo-Brush '#1F2C44'
    } else {
      $b.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
      $b.ClearValue([System.Windows.Controls.Control]::BorderThicknessProperty)
      $b.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
    }
  }
}

function Apply-Theme {
  param([string]$Name, [switch]$NoSave)
  if (-not $script:Themes.Contains($Name)) { $Name = '石墨' }
  $p = $script:Themes[$Name]
  $script:ThemeName = $Name
  foreach ($k in @('Bg','Panel','PanelHi','Card','CardHi','Stroke','StrokeHi','Text','Sub','Dim')) { Set-ThemeBrush $k $p[$k] }
  try { $win.Background = New-LiveBrush $p['Bg'] } catch {}
  try {
    $g = $win.Resources['WindowBg']
    if ($g -is [System.Windows.Media.LinearGradientBrush]) {
      if ($g.IsFrozen) { $g = $g.Clone(); $win.Resources['WindowBg'] = $g }
      $g.GradientStops[0].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($p['WinTop'])
      $g.GradientStops[1].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($p['WinBottom'])
    }
  } catch {}
  try {
    $hg = $win.FindName('DetailHeadBg')
    if ($hg -is [System.Windows.Media.LinearGradientBrush] -and -not $hg.IsFrozen) {
      $hg.GradientStops[0].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($p['PanelHi'])
      $hg.GradientStops[1].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($p['Card'])
    }
  } catch {}
  Update-ThemeBtns
  $cfg.theme = $Name
  if (-not $NoSave) { try { Save-SmConfig $cfg } catch {} }
}

function Get-KindMeta {
  param([string]$Kind)
  switch ($Kind) {
    'Run'           { return @{ Label = '启动项'; Hex = '#6EA8FE'; Bg = '#3E3F3F' } }
    'RunOnce'       { return @{ Label = '一次性'; Hex = '#EAEBEB'; Bg = '#3C3C3D' } }
    'StartupFolder' { return @{ Label = '启动夹'; Hex = '#B48EF0'; Bg = '#3E3F3F' } }
    'Task'          { return @{ Label = '任务';   Hex = '#F0B45B'; Bg = '#2A2113' } }
    'UWP'           { return @{ Label = '应用';   Hex = '#35D399'; Bg = '#12291F' } }
    'Service'       { return @{ Label = '服务';   Hex = '#EAEBEB'; Bg = '#353536' } }
    'Quarantine'    { return @{ Label = '被拦截'; Hex = '#F0B45B'; Bg = '#2A2113' } }
    default         { return @{ Label = '其他';   Hex = '#EAEBEB'; Bg = '#353536' } }
  }
}

function ConvertTo-Brush {
  param([string]$Hex)
  $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
  $b.Freeze()
  return $b
}

function New-ItemVm {
  param($Item)
  $meta = Get-KindMeta $Item.Kind
  $on = ($Item.State -eq 'Enabled')
  $canToggle = [bool]$Item.Supported -and -not ($Item.RequiresAdmin -and -not $isAdmin)
  if ($Item.Kind -eq 'Quarantine') { $canToggle = $true }
  $stateText = '已启用'
  $stateHex = '#35D399'
  if (-not $on) { $stateText = '已禁用'; $stateHex = '#BFBFC0' }
  if (-not $Item.Supported) { $stateText = '只读'; $stateHex = '#BFBFC0' }
  if ($Item.RequiresAdmin -and -not $isAdmin -and $Item.Supported) { $stateText = '需提权'; $stateHex = '#F0B45B' }
  if ($Item.Kind -eq 'Quarantine') { $stateText = '被拦截'; $stateHex = '#F0B45B' }

  $pathText = [string]$Item.Command
  if ([string]::IsNullOrWhiteSpace($pathText)) { $pathText = [string]$Item.Location }
  if ($pathText.Length -gt 120) { $pathText = $pathText.Substring(0, 118) + '…' }

  $initial = '?'
  if (-not [string]::IsNullOrWhiteSpace($Item.Name)) { $initial = ([string]$Item.Name).Substring(0, 1).ToUpperInvariant() }
  if ($Item.IconPath) { $initial = '' }

  return [pscustomobject]@{
    Name        = $Item.Name
    Initial     = $initial
    KindLabel   = $meta.Label
    KindBrush   = [string]$meta.Hex
    KindBg      = [string]$meta.Bg
    PathText    = $pathText
    Location    = [string]$Item.Location
    IconPath    = $Item.IconPath
    IsOn        = $on
    StateText   = $stateText
    StateBrush  = [string]$stateHex
    CanToggle   = $canToggle
    NeedsAdmin  = [bool]($Item.RequiresAdmin -and -not $isAdmin)
    Item        = $Item
    SearchText  = ((([string]$Item.Name) + ' ' + ([string]$Item.Command) + ' ' + ([string]$Item.Location) + ' ' + ([string]$Item.Publisher)).ToLowerInvariant())
  }
}

function New-AdviceVm {
  param($Item, $Advice)
  $meta = Get-KindMeta $Item.Kind
  $on = ($Item.State -eq 'Enabled')
  if ($Item.Kind -eq 'Quarantine') { $on = $false }
  $canToggle = [bool]$Item.Supported -and -not ($Item.RequiresAdmin -and -not $isAdmin)
  if ($Item.Kind -eq 'Quarantine') { $canToggle = $true }

  $stateText = '已启用'
  $stateHex = '#35D399'
  if (-not $on) { $stateText = '已禁用'; $stateHex = '#BFBFC0' }
  if ($Item.RequiresAdmin -and -not $isAdmin -and $Item.Supported) { $stateText = '需提权'; $stateHex = '#F0B45B' }
  if ($Item.Kind -eq 'Quarantine') { $stateText = '被拦截'; $stateHex = '#F0B45B' }

  $initial = '?'
  if (-not [string]::IsNullOrWhiteSpace($Item.Name)) { $initial = ([string]$Item.Name).Substring(0, 1).ToUpperInvariant() }
  if ($Item.IconPath) { $initial = '' }

  # 首条利弊（用于卡片摘要）
  $pros = ''
  $cons = ''
  try {
    if (@($Advice.DisPros).Count -gt 0) { $pros = '省 ' + [string](@($Advice.DisPros)[0]) }
    elseif (@($Advice.KeepPros).Count -gt 0) { $pros = '留 ' + [string](@($Advice.KeepPros)[0]) }
    if (@($Advice.DisCons).Count -gt 0) { $cons = '代价 ' + [string](@($Advice.DisCons)[0]) }
  } catch {}
  if ($pros.Length -gt 60) { $pros = $pros.Substring(0, 58) + '…' }
  if ($cons.Length -gt 60) { $cons = $cons.Substring(0, 58) + '…' }

  return [pscustomobject]@{
    Name         = $Item.Name
    Initial      = $initial
    IconPath     = $Item.IconPath
    KindLabel    = $meta.Label
    KindBrush    = [string]$meta.Hex
    KindBg       = [string]$meta.Bg
    Verdict      = [string]$Advice.Verdict
    VerdictLabel = [string]$Advice.VerdictLabel
    VerdictBrush = [string]$Advice.VerdictHex
    VerdictBg    = [string]($Advice.VerdictHex + '26')
    Purpose      = [string]$Advice.Purpose
    ProsText     = $pros
    ConsText     = $cons
    IsOn         = $on
    StateText    = $stateText
    StateBrush   = [string]$stateHex
    CanToggle    = $canToggle
    NeedsAdmin   = [bool]($Item.RequiresAdmin -and -not $isAdmin)
    Item         = $Item
  }
}

function Build-AdviceRows {
  # 对当前已扫描项生成建议清单（跳过事实采集，0.3 秒内完成）
  $rows = New-Object System.Collections.ArrayList
  # 只收当前真正会自启动的项；被拦截项已在「被拦截项」单独管理，不混进建议清单
  $src = @($script:AllItems | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' -and -not $_.Protected })
  foreach ($it in $src) {
    $adv = $null
    try { $adv = Get-ItemAdvice $it -SkipFacts } catch { continue }
    if (-not $adv) { continue }
    $null = $rows.Add((New-AdviceVm -Item $it -Advice $adv))
  }
  # 排序：建议禁用 → 可以禁用 → 看你用不用 → 不建议禁用；同级按名称
  $rank = @{ 'recommend' = 0; 'free' = 1; 'caution' = 2; 'keep' = 3 }
  $script:AdviceRows = @($rows | Sort-Object -Property @{ Expression = { $r = $rank[[string]$_.Verdict]; if ($null -eq $r) { 4 } else { $r } } }, Name)
  $script:AdvReady = $true
}

function Get-AdviceFiltered {
  $src = @($script:AdviceRows)
  if ($script:AdvVerdictFilter -ne 'all') {
    $src = @($src | Where-Object { $_.Verdict -eq $script:AdvVerdictFilter })
  }
  $q = [string]$ui.SearchBox.Text
  if ($q) {
    $qq = $q.ToLowerInvariant()
    $src = @($src | Where-Object {
      (([string]$_.Name).ToLowerInvariant().Contains($qq)) -or
      (([string]$_.Purpose).ToLowerInvariant().Contains($qq))
    })
  }
  return $src
}

function Refresh-Advice {
  if (-not $script:AdvReady) { Build-AdviceRows }
  $rows = @(Get-AdviceFiltered)
  $oc = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  foreach ($r in $rows) { $null = $oc.Add($r) }
  $ui.AdviceList.ItemsSource = $oc

  $total = @($script:AdviceRows).Count
  $rec = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'recommend' }).Count
  $free = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'free' }).Count
  $cau = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'caution' }).Count
  $keep = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'keep' }).Count

  $ui.AdviceSummary.Text = ('共 ' + $total + ' 项 · 建议禁用 ' + $rec + ' · 可以禁用 ' + $free + ' · 看你用不用 ' + $cau)
  $ui.AdviceHeader.Text = ('下面是本机全部可切换的自启动项，按「建议程度」从高到低排序。建议禁用 ' + $rec + ' 项，可以禁用 ' + $free + ' 项，看你用不用 ' + $cau + ' 项，不建议禁用 ' + $keep + ' 项。点任意一行可查看完整说明与利弊，右侧开关直接生效。当前筛选：' + $(if ($script:AdvVerdictFilter -eq 'all') { '全部' } else { $script:AdvVerdictFilter }))
  if ($rows.Count -eq 0) { $ui.AdviceEmpty.Visibility = 'Visible'; $ui.AdviceEmpty.Text = '该分类下没有项目' } else { $ui.AdviceEmpty.Visibility = 'Collapsed' }
  if ($ui.StatTotal) { Update-Stats $script:AllItems }
}

function Update-AdvFilterBtns {
  $map = @{ 'all' = $ui.AdvFilterAll; 'recommend' = $ui.AdvFilterRec; 'free' = $ui.AdvFilterFree; 'caution' = $ui.AdvFilterCau; 'keep' = $ui.AdvFilterKeep }
  foreach ($k in $map.Keys) {
    $b = $map[$k]
    if (-not $b) { continue }
    if ($k -eq $script:AdvVerdictFilter) {
      $b.Background = ConvertTo-Brush '#233FD9FF'
      $b.BorderBrush = ConvertTo-Brush '#5B8DEF'
      $b.Foreground = ConvertTo-Brush '#FFFFFF'
    } else {
      $b.Background = ConvertTo-Brush '#323233'
      $b.BorderBrush = ConvertTo-Brush '#575859'
      $b.Foreground = ConvertTo-Brush '#EAEBEB'
    }
  }
}

function Update-Stats {
  # 概览卡片：全部/已启用/已禁用/建议优化
  param($Items)
  $vis = @($Items)
  if (-not $cfg.showSystemItems) { $vis = @($vis | Where-Object { -not $_.Protected }) }
  $tot = @($vis | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' }).Count
  $on  = @($vis | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' -and $_.State -eq 'Enabled' }).Count
  $off = @($vis | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' -and $_.State -ne 'Enabled' }).Count
  $sugg = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'recommend' }).Count

  $ui.StatTotal.Text = [string]$tot
  $ui.StatOn.Text    = [string]$on
  $ui.StatOff.Text   = [string]$off
  if ($sugg -gt 0) { $ui.StatSugg.Text = [string]$sugg } else { $ui.StatSugg.Text = '0' }
}

function Update-NavCounts {
  param($Items)
  $vis = @($Items)
  if (-not $cfg.showSystemItems) { $vis = @($vis | Where-Object { -not $_.Protected }) }
  $map = @{}
  $map['all'] = @($vis | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' }).Count
  $map['user'] = @($vis | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' -and $_.Scope -eq 'User' }).Count
  $map['machine'] = @($vis | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' -and $_.Scope -eq 'Machine' }).Count
  $map['quar'] = @($vis | Where-Object { $_.Kind -eq 'Quarantine' }).Count
  $map['task'] = @($vis | Where-Object { $_.Kind -eq 'Task' }).Count
  $map['uwp'] = @($vis | Where-Object { $_.Kind -eq 'UWP' }).Count
  $map['service'] = @($vis | Where-Object { $_.Kind -eq 'Service' }).Count
  $map['advice'] = @($script:AdviceRows).Count
  $map['changes'] = $script:ChangeVms.Count
  $script:NavCounts = $map
}

function Build-Nav {
  $list = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  foreach ($d in $script:NavDefs) {
    $c = 0
    if ($script:NavCounts -and $script:NavCounts.ContainsKey($d.Key)) { $c = $script:NavCounts[$d.Key] }
    $cntText = [string]$c
    if ($d.Key -eq 'settings') { $cntText = '' }
    $list.Add([pscustomobject]@{
      Key   = $d.Key
      Label = $d.Label
      Count = $cntText
      HasCount = ($cntText -ne '')
      Hex   = [string]$d.Hex
      IsSel = ($d.Key -eq $script:CurrentNav)
    })
  }
  $isBusy = $script:NavBusy
  $script:NavBusy = $true
  $ui.NavList.ItemsSource = $list
  $idx = 0
  for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Key -eq $script:CurrentNav) { $idx = $i; break } }
  if ($list.Count -gt 0) { $ui.NavList.SelectedIndex = $idx }
  $script:NavBusy = $isBusy
}

function Get-FilteredItems {
  param([string]$Nav, [string]$Query)
  $src = $script:AllItems
  if ($Nav -eq 'user') { $src = @($src | Where-Object { $_.Supported -and $_.Scope -eq 'User' }) }
  elseif ($Nav -eq 'machine') { $src = @($src | Where-Object { $_.Supported -and $_.Scope -eq 'Machine' }) }
  elseif ($Nav -eq 'task') { $src = @($src | Where-Object { $_.Kind -eq 'Task' }) }
  elseif ($Nav -eq 'uwp') { $src = @($src | Where-Object { $_.Kind -eq 'UWP' }) }
  elseif ($Nav -eq 'service') { $src = @($src | Where-Object { $_.Kind -eq 'Service' }) }
  elseif ($Nav -eq 'quar') { $src = @($src | Where-Object { $_.Kind -eq 'Quarantine' }) }
  else { $src = @($src | Where-Object { $_.Supported -and $_.Kind -ne 'Quarantine' }) }

  if (-not $cfg.showSystemItems) {
    $src = @($src | Where-Object { -not $_.Protected })
  }
  if ($Query) {
    $q = $Query.ToLowerInvariant()
    $src = @($src | Where-Object {
      (([string]$_.Name).ToLowerInvariant().Contains($q)) -or
      (([string]$_.Command).ToLowerInvariant().Contains($q)) -or
      (([string]$_.Location).ToLowerInvariant().Contains($q))
    })
  }
  return @($src | Sort-Object -Property @{ Expression = { if ($_.State -eq 'Enabled') { 0 } else { 1 } } }, Kind, Name)
}

function Refresh-View {
  $isChanges = ($script:CurrentNav -eq 'changes')
  if ($script:CurrentNav -eq 'settings') {
    $ui.ItemsList.Visibility = 'Collapsed'
    $ui.ChangesPanel.Visibility = 'Collapsed'
    $ui.AdvicePanel.Visibility = 'Collapsed'
    $ui.SettingsPanel.Visibility = 'Visible'
    $ui.ListHeader.Visibility = 'Collapsed'
    $ui.EmptyHint.Visibility = 'Collapsed'
    Refresh-Settings
    return
  }
  if ($ui.SettingsPanel) { $ui.SettingsPanel.Visibility = 'Collapsed' }
  $isAdvice = ($script:CurrentNav -eq 'advice')
  if ($isChanges) {
    $ui.ItemsList.Visibility = 'Collapsed'
    $ui.ChangesPanel.Visibility = 'Visible'
    $ui.AdvicePanel.Visibility = 'Collapsed'
    $ui.ListHeader.Visibility = 'Collapsed'
    $ui.EmptyHint.Visibility = 'Collapsed'
    $ui.ChangesHeader.Text = ('最近变更 · 共 ' + $script:ChangeVms.Count + ' 条')
    return
  }
  if ($isAdvice) {
    $ui.ItemsList.Visibility = 'Collapsed'
    $ui.ChangesPanel.Visibility = 'Collapsed'
    $ui.AdvicePanel.Visibility = 'Visible'
    $ui.ListHeader.Visibility = 'Collapsed'
    $ui.EmptyHint.Visibility = 'Collapsed'
    Update-AdvFilterBtns
    if (-not $script:AdvReady -and @($script:AllItems).Count -gt 0) { Build-AdviceRows }
    if ($script:AdvReady) { Refresh-Advice }
    return
  }
  $ui.ItemsList.Visibility = 'Visible'
  $ui.ChangesPanel.Visibility = 'Collapsed'
  $ui.AdvicePanel.Visibility = 'Collapsed'
  $ui.ListHeader.Visibility = 'Visible'

  $q = [string]$ui.SearchBox.Text
  $items = Get-FilteredItems -Nav $script:CurrentNav -Query $q

  $script:ViewVms.Clear()
  foreach ($it in $items) { $script:ViewVms.Add((New-ItemVm $it)) }
  $ui.ItemsList.ItemsSource = $script:ViewVms

  $label = $items.Count
  if ($script:CurrentNav -eq 'quar') { $ui.ListHeader.Text = ('共 ' + $label + ' 项 · 被联想电脑管家拦截，打开开关可尝试恢复') }
  else { $ui.ListHeader.Text = ('共 ' + $label + ' 项 · 登录时/开机时自动运行') }
  if ($items.Count -eq 0) { $ui.EmptyHint.Visibility = 'Visible' } else { $ui.EmptyHint.Visibility = 'Collapsed' }
}

function Set-Status {
  param([string]$Text, [string]$Color = '#35D399')
  $ui.StatusText.Text = $Text
  $ui.StatusDot.Fill = ConvertTo-Brush $Color
}

# ---------- 扫描（后台） ----------
function Start-Scan {
  param([switch]$KeepStatus)
  if ($script:ScanPs) { return }
  if (-not $KeepStatus) { Set-Status '正在扫描启动项…' '#F0B45B' }
  $corePath = Join-Path $root 'lib\Core.ps1'
  $ps = [PowerShell]::Create()
  $null = $ps.AddScript('. "' + $corePath + '"; Get-StartupItems -IncludeServices | ConvertTo-Json -Depth 4 -Compress')
  $ps.RunspacePool = $script:Pool
  $script:ScanPs = $ps
  $script:ScanSw.Restart()
  $script:ScanHandle = $ps.BeginInvoke()
}

function Finish-Scan {
  if (-not $script:ScanPs) { return }
  if (-not $script:ScanHandle.IsCompleted) { return }
  $items = @()
  try {
    $out = $script:ScanPs.EndInvoke($script:ScanHandle)
    $json = [string]($out | Select-Object -Last 1)
    if ($json -and $json.Length -gt 2) {
      $raw = $json | ConvertFrom-Json
      foreach ($r in $raw) {
        $r | Add-Member -NotePropertyName 'Raw' -NotePropertyValue ([pscustomobject]$r.Raw) -Force
        $items += $r
      }
    }
  } catch {
    Set-Status ('扫描失败: ' + $_.Exception.Message) '#F0716E'
  } finally {
    try { $script:ScanPs.Dispose() } catch {}
    $script:ScanPs = $null
    $script:ScanHandle = $null
  }
  if ($items.Count -eq 0) {
    if ($ui.StatusText.Text -notlike '扫描失败*') { Set-Status '扫描完成，但未发现启动项' '#EAEBEB' }
    return
  }

  $script:AllItems = $items
  $snap = Get-Snapshot $items
  $old = Read-PreviousSnapshot
  $changes = Compare-Snapshot -Old $old -New $snap
  Write-SmLog ('扫描完成: ' + $items.Count + ' 项, 变更 ' + @($changes).Count + ' 条, autoDisable=' + $cfg.autoDisableNew)
  # 新增自启动项自动禁用（首次运行不触发，因为快照为空）
  $autoOff = 0
  try {
    $chgArr = @($changes)
    if ($cfg.autoDisableNew -and $chgArr.Count -gt 0) {
      foreach ($ch in $chgArr) {
        if ($ch.Type -ne 'added') { continue }
        $hit = $items | Where-Object { $_.Id -eq $ch.Id } | Select-Object -First 1
        if (-not $hit) { Write-SmLog ('自动禁用跳过(找不到项): ' + $ch.Id) 'WARN'; continue }
        if ($hit.Kind -eq 'Quarantine') { Write-SmLog ('自动禁用跳过(已被第三方拦截): ' + $hit.Name) 'WARN'; continue }
        if (-not $hit.Supported) { Write-SmLog ('自动禁用跳过(只读): ' + $hit.Name) 'WARN'; continue }
        if ($hit.State -ne 'Enabled') { Write-SmLog ('自动禁用跳过(已禁用): ' + $hit.Name) 'WARN'; continue }
        if ($hit.RequiresAdmin -and -not $isAdmin) { Write-SmLog ('自动禁用跳过(需管理员): ' + $hit.Name) 'WARN'; continue }
        $rr = Set-StartupItemState -Item $hit -Enabled $false
        if ($rr.Ok) {
          $hit.State = 'Disabled'
          $ch.Detail = '新发现自启动项 · 已自动禁用'
          $autoOff++
          Write-SmLog ('自动禁用成功: ' + $hit.Name) 'INFO'
        } else {
          Write-SmLog ('自动禁用失败: ' + $hit.Name + ' -> ' + $rr.Error) 'WARN'
        }
      }
      if ($autoOff -gt 0) { $snap = Get-Snapshot $items }
    }
  } catch {
    Write-SmLog ('自动禁用异常: ' + $_.Exception.Message) 'ERROR'
  }
  $chgArr2 = @($changes)
  Save-Snapshot $snap
  if ($chgArr2.Count -gt 0) {
    Add-ChangeLog $chgArr2
    Load-Changes
  }
  Update-NavCounts $items
  Build-Nav
  Refresh-View
  Update-Stats $items
  $enabled = @($items | Where-Object { $_.State -eq 'Enabled' -and $_.Supported }).Count
  $secs = [math]::Round($script:ScanSw.Elapsed.TotalSeconds, 1)
  Set-Status ('已扫描 ' + $items.Count + ' 项 · 启用中 ' + $enabled + ' 项 · 用时 ' + $secs + 's') '#35D399'
  $ui.WatcherText.Text = ('监控中 · 每 ' + $cfg.watchSeconds + ' 秒同步一次')
}

function Load-Changes {
  $script:ChangeVms.Clear()
  $recs = @(Get-RecentChanges 120)
  [array]::Reverse($recs)
  foreach ($r in $recs) {
    $label = '新增'; $hex = '#35D399'; $bghex = '#12291F'
    if ($r.type -eq 'removed') { $label = '移除'; $hex = '#F0716E'; $bghex = '#2B1719' }
    elseif ($r.type -eq 'state') { $label = '状态'; $hex = '#F0B45B'; $bghex = '#2A2113' }
    elseif ($r.type -eq 'changed') { $label = '变更'; $hex = '#6EA8FE'; $bghex = '#3E3F3F' }
    $t = ''
    try { $t = ([datetime]$r.time).ToString('MM-dd HH:mm') } catch { $t = [string]$r.time }
    $script:ChangeVms.Add([pscustomobject]@{
      TimeText  = $t
      TypeLabel = $label
      TypeBrush = [string]$hex
      TypeBg    = [string]$bghex
      Name      = [string]$r.name
      Detail    = [string]$r.detail
    })
  }
  $ui.ChangesList.ItemsSource = $script:ChangeVms
}

# ---------- 详情弹层 ----------
$script:DetailVm = $null

function New-FactRow {
  param([string]$Key, [string]$Value)
  $g = New-Object System.Windows.Controls.Grid
  $g.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
  $c1 = New-Object System.Windows.Controls.ColumnDefinition
  $c1.Width = New-Object System.Windows.GridLength(76)
  $c2 = New-Object System.Windows.Controls.ColumnDefinition
  $null = $g.ColumnDefinitions.Add($c1)
  $null = $g.ColumnDefinitions.Add($c2)
  $t1 = New-Object System.Windows.Controls.TextBlock
  $t1.Text = $Key
  $t1.Foreground = ConvertTo-Brush "#A4A5A6"
  $t1.FontSize = 11.5
  $t1.VerticalAlignment = "Top"
  [System.Windows.Controls.Grid]::SetColumn($t1, 0)
  $t2 = New-Object System.Windows.Controls.TextBlock
  $t2.Text = $Value
  $t2.Foreground = ConvertTo-Brush "#EAEBEB"
  $t2.FontSize = 11.5
  $t2.TextWrapping = "Wrap"
  [System.Windows.Controls.Grid]::SetColumn($t2, 1)
  $null = $g.Children.Add($t1)
  $null = $g.Children.Add($t2)
  return $g
}

function Format-Bullets {
  param($Pros, $Cons)
  $lines = New-Object System.Collections.ArrayList
  foreach ($x in @($Pros)) { if (-not [string]::IsNullOrWhiteSpace([string]$x)) { $null = $lines.Add("✓  " + [string]$x) } }
  foreach ($x in @($Cons)) { if (-not [string]::IsNullOrWhiteSpace([string]$x)) { $null = $lines.Add("✕  " + [string]$x) } }
  if ($lines.Count -eq 0) { return "暂无可用信息" }
  return ($lines -join [Environment]::NewLine)
}

function Show-ItemDetail {
  param($Vm)
  if (-not $Vm) { return }
  $script:DetailVm = $Vm
  $a = $null
  try { $a = Get-ItemAdvice $Vm.Item } catch { }
  if (-not $a) {
    $ui.DetailTitle.Text = $Vm.Name
    $ui.DetailSub.Text = ""
    $ui.VerdictText.Text = "信息不足"
    $ui.PurposeText.Text = "无法读取该项的详细信息。"
    $ui.WhyText.Text = ""
    $ui.DisText.Text = "—"
    $ui.KeepText.Text = "—"
    $ui.FactsPanel.Children.Clear()
    $ui.DetailToggleBtn.Visibility = "Collapsed"
    $ui.DetailOverlay.Visibility = "Visible"
    return
  }

  $ui.DetailTitle.Text = [string]$a.Name
  $ui.DetailSub.Text = [string]$a.App

  $ui.VerdictText.Text = [string]$a.VerdictLabel
  $ui.VerdictText.Foreground = ConvertTo-Brush $a.VerdictHex
  $ui.VerdictBadge.Background = ConvertTo-Brush ($a.VerdictHex + "26")

  $ui.PurposeText.Text = [string]$a.Purpose
  $ui.WhyText.Text = ([string]$a.Why) + [Environment]::NewLine + [string]$a.VerdictDesc

  $ui.DisText.Text = Format-Bullets -Pros $a.DisPros -Cons $a.DisCons
  $ui.KeepText.Text = Format-Bullets -Pros $a.KeepPros -Cons $a.KeepCons

  $ui.FactsPanel.Children.Clear()
  foreach ($f in @($a.Facts)) {
    $null = $ui.FactsPanel.Children.Add((New-FactRow -Key ([string]$f.Key) -Value ([string]$f.Value)))
  }

  $isOn = [bool]$Vm.IsOn
  if ($Vm.CanToggle) {
    $ui.DetailToggleBtn.Visibility = "Visible"
    if ($isOn) { $ui.DetailToggleBtn.Content = "禁用此项" } else { $ui.DetailToggleBtn.Content = "启用此项" }
    if ($isOn) { $ui.DetailHint.Text = "该操作会先备份当前状态，之后可在任务管理器里改回。" }
    else { $ui.DetailHint.Text = "打开后，它会在下次登录时随系统启动。" }
  } else {
    $ui.DetailToggleBtn.Visibility = "Collapsed"
    if ($Vm.NeedsAdmin) { $ui.DetailHint.Text = "该项为系统级启动项，需要以管理员身份重启本程序才能修改。" }
    else { $ui.DetailHint.Text = "该项为只读（系统服务或受保护项），本程序不提供直接切换。" }
  }

  $ui.DetailOverlay.Visibility = "Visible"
}

function Hide-ItemDetail {
  $ui.DetailOverlay.Visibility = "Collapsed"
  $script:DetailVm = $null
}

# ---------- 交互 ----------
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 2)
$script:Pool.Open()

$ui.NavList.Add_SelectionChanged({
  if ($script:NavBusy) { return }
  $sel = $ui.NavList.SelectedItem
  if (-not $sel) { return }
  $script:CurrentNav = $sel.Key
  Refresh-View
})

$ui.SearchBox.Add_TextChanged({
  if ([string]::IsNullOrEmpty($ui.SearchBox.Text)) { $ui.SearchHint.Visibility = 'Visible' } else { $ui.SearchHint.Visibility = 'Collapsed' }
  if ($script:CurrentNav -eq 'advice') { if ($script:AdvReady) { Refresh-Advice } }
  elseif ($script:CurrentNav -ne 'changes') { Refresh-View }
})

$ui.RefreshBtn.Add_Click({
  $script:BootMs.Restart()
  Start-Scan -KeepStatus
})

$ui.ElevateBtn.Add_Click({
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $root 'main.ps1') + '"'
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    $win.Close()
  } catch {
    Set-Status '提权已取消' '#E0A93B'
  }
})

# 一键扫描建议：切到推荐清单并生成
function Open-AdviceView {
  $script:CurrentNav = 'advice'
  $ui.NavList.SelectedIndex = -1
  foreach ($d in $script:NavDefs) {
    if ($d.Key -eq 'advice') { break }
  }
  Set-Status '正在生成建议清单…' '#E0A93B'
  try {
    Build-AdviceRows
    Update-NavCounts $script:AllItems
    Build-Nav
    foreach ($x in $ui.NavList.Items) { if ($x.Key -eq 'advice') { $ui.NavList.SelectedItem = $x; break } }
    Refresh-View
    $rec = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'recommend' }).Count
    $free = @($script:AdviceRows | Where-Object { $_.Verdict -eq 'free' }).Count
    Set-Status ('建议清单已生成 · 建议禁用 ' + $rec + ' 项 · 可以禁用 ' + $free + ' 项') '#3ECF8E'
  } catch {
    Set-Status ('生成建议清单失败: ' + $_.Exception.Message) '#E86A6A'
  }
}

$ui.AdviceBtn.Add_Click({ Open-AdviceView })
$ui.AdviceScanBtn.Add_Click({
  Set-Status '重新生成建议清单…' '#E0A93B'
  Build-AdviceRows
  Update-NavCounts $script:AllItems
  Build-Nav
  Refresh-Advice
  Set-Status ('建议清单已刷新 · 共 ' + @($script:AdviceRows).Count + ' 项') '#3ECF8E'
})

foreach ($fb in @($ui.AdvFilterAll, $ui.AdvFilterRec, $ui.AdvFilterFree, $ui.AdvFilterCau, $ui.AdvFilterKeep)) {
  if ($fb) {
    $fb.Add_Click({
      param($s2, $e2)
      $script:AdvVerdictFilter = [string]$s2.Tag
      Update-AdvFilterBtns
      Refresh-Advice
    })
  }
}

# ---------- 开机自启 / 设置页 / 托盘 ----------
$script:AppVersion = '2.0.0'

function Open-InExplorer {
  param([string]$Path, [switch]$Select)
  try {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($Select -and (Test-Path -LiteralPath $Path)) { Start-Process explorer.exe -ArgumentList ('/select,"' + $Path + '"') }
    elseif (Test-Path -LiteralPath $Path) { Start-Process explorer.exe -ArgumentList ('"' + $Path + '"') }
  } catch { Set-Status ('打开位置失败: ' + $_.Exception.Message) '#F0716E' }
}

function Get-ItemTargetPath {
  param($Item)
  $p = ''
  try { $p = [string](Resolve-ExeFromCommand ([string]$Item.Command)) } catch { $p = '' }
  if ([string]::IsNullOrWhiteSpace($p)) { $p = [string]$Item.Location }
  return $p
}

function Update-WatchBtns {
  foreach ($b in @($ui.WatchBtn0, $ui.WatchBtn1, $ui.WatchBtn2, $ui.WatchBtn3)) {
    if (-not $b) { continue }
    if ([int]$b.Tag -eq [int]$cfg.watchSeconds) {
      $b.BorderBrush = ConvertTo-Brush '#5B8DEF'
      $b.BorderThickness = New-Object System.Windows.Thickness(1.5)
      $b.Background = ConvertTo-Brush '#1F2C44'
    } else {
      $b.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
      $b.ClearValue([System.Windows.Controls.Control]::BorderThicknessProperty)
      $b.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
    }
  }
}

function Refresh-Settings {
  if (-not $ui.SettingsPanel) { return }
  try { $ui.IgnoreBox.Text = (@($cfg.ignoreNames) -join [Environment]::NewLine) } catch {}
  try { $ui.SetSelfStartBox.IsChecked = [bool](Test-SelfStart) } catch {}
  try { $ui.SetAutoDisableBox.IsChecked = [bool]$cfg.autoDisableNew } catch {}
  try { $ui.SetShowSystemBox.IsChecked = [bool]$cfg.showSystemItems } catch {}
  try { $ui.AboutVersion.Text = ('v' + $script:AppVersion) } catch {}
  try { $ui.AboutPath.Text = $root } catch {}
  try { $ui.AboutData.Text = $script:Paths.State } catch {}
  try { $ui.AboutState.Text = ('已识别 ' + @($script:AllItems).Count + ' 项 · 每 ' + $cfg.watchSeconds + ' 秒同步') } catch {}
  Update-WatchBtns
  Update-ThemeBtns
  try {
    $ui.SettingsPanel.ScrollToTop()
    $null = $ui.SettingsPanel.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ try { $ui.SettingsPanel.ScrollToVerticalOffset(0) } catch {} })
  } catch {}
}

$script:SyncBusy = $false

function Set-AutoDisablePref {
  param([bool]$On)
  if ($script:SyncBusy) { return }
  $script:SyncBusy = $true
  try {
    if ([bool]$cfg.autoDisableNew -ne $On) {
      $cfg.autoDisableNew = $On
      Save-SmConfig $cfg
      if ($On) { Write-SmLog '自动禁用新启动项: 已开启' } else { Write-SmLog '自动禁用新启动项: 已关闭' }
      if ($On) { Set-Status '新增自启动项将自动禁用' '#35D399' } else { Set-Status '新增自启动项不再自动禁用' '#8A8B8C' }
    }
    if ($ui.AutoDisableBox) { $ui.AutoDisableBox.IsChecked = $On }
    if ($ui.SetAutoDisableBox) { $ui.SetAutoDisableBox.IsChecked = $On }
  } finally { $script:SyncBusy = $false }
}

function Set-SelfStartPref {
  param([bool]$On)
  if ($script:SyncBusy) { return }
  $script:SyncBusy = $true
  try {
    $null = Set-SelfStart -Enabled $On -AppDir $root
    if ($ui.SelfStartBox) { $ui.SelfStartBox.IsChecked = $On }
    if ($ui.SetSelfStartBox) { $ui.SetSelfStartBox.IsChecked = $On }
    if ($On) { Set-Status '已设置开机自动运行' '#35D399' } else { Set-Status '已取消开机自动运行' '#8A8B8C' }
    Write-SmLog ('开机自启: ' + $(if ($On) { '开启' } else { '关闭' }))
  } catch {
    Set-Status ('设置开机自启失败: ' + $_.Exception.Message) '#F0716E'
  } finally { $script:SyncBusy = $false }
}

function Set-ShowSystemPref {
  param([bool]$On)
  if ($script:SyncBusy) { return }
  $script:SyncBusy = $true
  try {
    $cfg.showSystemItems = $On
    Save-SmConfig $cfg
    if ($ui.SetShowSystemBox) { $ui.SetShowSystemBox.IsChecked = $On }
    Update-NavCounts $script:AllItems
    Build-Nav
    Refresh-View
    Update-Stats $script:AllItems
  } finally { $script:SyncBusy = $false }
}

function Show-AppWindow {
  try {
    $win.Show()
    if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
    $win.Activate()
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    [SmNative]::SetForegroundWindow($h) | Out-Null
  } catch {}
}

$ui.AutoDisableBox.Add_Checked({ if ($script:SyncBusy) { return }; Set-AutoDisablePref $true })
$ui.AutoDisableBox.Add_Unchecked({ if ($script:SyncBusy) { return }; Set-AutoDisablePref $false })
$ui.SelfStartBox.Add_Checked({ if ($script:SyncBusy) { return }; Set-SelfStartPref $true })
$ui.SelfStartBox.Add_Unchecked({ if ($script:SyncBusy) { return }; Set-SelfStartPref $false })
$ui.SetAutoDisableBox.Add_Checked({ if ($script:SyncBusy) { return }; Set-AutoDisablePref $true })
$ui.SetAutoDisableBox.Add_Unchecked({ if ($script:SyncBusy) { return }; Set-AutoDisablePref $false })
$ui.SetSelfStartBox.Add_Checked({ if ($script:SyncBusy) { return }; Set-SelfStartPref $true })
$ui.SetSelfStartBox.Add_Unchecked({ if ($script:SyncBusy) { return }; Set-SelfStartPref $false })
$ui.SetShowSystemBox.Add_Checked({ if ($script:SyncBusy) { return }; Set-ShowSystemPref $true })
$ui.SetShowSystemBox.Add_Unchecked({ if ($script:SyncBusy) { return }; Set-ShowSystemPref $false })

foreach ($tb in @($ui.ThemeBtn0, $ui.ThemeBtn1, $ui.ThemeBtn2, $ui.ThemeBtn3)) {
  if ($tb) {
    $tb.Add_Click({
      param($s2, $e2)
      Apply-Theme ([string]$s2.Tag)
      Set-Status ('配色已切换为「' + [string]$s2.Tag + '」') '#35D399'
    })
  }
}

foreach ($wb in @($ui.WatchBtn0, $ui.WatchBtn1, $ui.WatchBtn2, $ui.WatchBtn3)) {
  if ($wb) {
    $wb.Add_Click({
      param($s2, $e2)
      $cfg.watchSeconds = [int]$s2.Tag
      if ($cfg.watchSeconds -lt 3) { $cfg.watchSeconds = 3 }
      Save-SmConfig $cfg
      Update-WatchBtns
      $ui.WatcherText.Text = ('监控中 · 每 ' + $cfg.watchSeconds + ' 秒同步一次')
      Set-Status ('同步间隔已改为 ' + $cfg.watchSeconds + ' 秒') '#35D399'
      if ($script:CurrentNav -eq 'settings') { Refresh-Settings }
    })
  }
}

$ui.IgnoreSaveBtn.Add_Click({
  $lines = @()
  try {
    $txt = [string]$ui.IgnoreBox.Text
    foreach ($ln in ($txt -split [char]10)) { $t2 = $ln.Trim(); if ($t2) { $lines += $t2 } }
  } catch {}
  $cfg.ignoreNames = @($lines)
  Save-SmConfig $cfg
  $ui.IgnoreHint.Text = '已保存，正在按新名单重新扫描'
  Start-Scan -KeepStatus
})

$ui.OpenDataBtn.Add_Click({ Open-InExplorer -Path $script:Paths.State })
$ui.OpenAppBtn.Add_Click({ Open-InExplorer -Path $root })
$ui.AboutDocBtn.Add_Click({
  $doc = Join-Path $root '说明.md'
  if (Test-Path -LiteralPath $doc) { Start-Process $doc } else { Set-Status '找不到说明文档' '#F0B45B' }
})

$ui.DetailOpenBtn.Add_Click({
  $vm = $script:DetailVm
  if (-not $vm) { return }
  $p = Get-ItemTargetPath $vm.Item
  if ($p -and (Test-Path -LiteralPath $p)) { Open-InExplorer -Path $p -Select }
  elseif ($p) {
    $dir = Split-Path $p -Parent
    if ($dir -and (Test-Path -LiteralPath $dir)) { Open-InExplorer -Path $dir } else { Set-Status '找不到该项所在位置' '#F0B45B' }
  } else { Set-Status '该项没有可打开的路径' '#F0B45B' }
})

# ---------- 托盘图标 ----------
$script:Tray = $null
try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $icoPath = Join-Path $root 'assets\app.ico'
  if (Test-Path -LiteralPath $icoPath) { $ico = New-Object System.Drawing.Icon($icoPath) } else { $ico = [System.Drawing.SystemIcons]::Application }
  $script:Tray = New-Object System.Windows.Forms.NotifyIcon
  $script:Tray.Icon = $ico
  $script:Tray.Text = '自启动管家'
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开主界面')
  $miScan = New-Object System.Windows.Forms.ToolStripMenuItem('立即重新扫描')
  $sep1 = New-Object System.Windows.Forms.ToolStripSeparator
  $miExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
  $null = $menu.Items.Add($miOpen)
  $null = $menu.Items.Add($miScan)
  $null = $menu.Items.Add($sep1)
  $null = $menu.Items.Add($miExit)
  $script:Tray.ContextMenuStrip = $menu
  $miOpen.Add_Click({ Show-AppWindow })
  $miScan.Add_Click({ Start-Scan; Show-AppWindow })
  $miExit.Add_Click({ try { $script:Tray.Visible = $false } catch {}; $win.Close() })
  $script:Tray.Add_DoubleClick({ param($s2, $e2) Show-AppWindow })
  $script:Tray.Visible = $true
} catch { Write-SmLog ('托盘初始化失败: ' + $_.Exception.Message) 'WARN' }

# 执行一次开关切换（供行内开关与详情弹层共用）
function Apply-Toggle {
  param($Vm, [bool]$Desired, $CheckBox = $null)
  if ($CheckBox) { $CheckBox.IsEnabled = $false }
  $verb = "禁用"
  if ($Desired) { $verb = "启用" }
  Set-Status ("正在" + $verb + " " + $Vm.Name + " …") "#E0A93B"
  $r = Set-StartupItemState -Item $Vm.Item -Enabled $Desired
  if ($CheckBox) { $CheckBox.IsEnabled = $true }

  if (-not $r.Ok) {
    if ($CheckBox) { $CheckBox.IsChecked = [bool]$Vm.IsOn }
    Set-Status ("操作失败: " + $r.Error) "#E86A6A"
    return $false
  }

  $idx = $script:ViewVms.IndexOf($Vm)
  if ($Vm.Item.Kind -eq "Quarantine" -and $Desired) {
    if ($idx -ge 0) { $script:ViewVms.RemoveAt($idx) }
    $script:AllItems = @($script:AllItems | Where-Object { $_.Id -ne $Vm.Item.Id })
    Update-NavCounts $script:AllItems
    Build-Nav
    if ($script:AdvReady) { try { Build-AdviceRows; Refresh-Advice } catch {} }
    Set-Status ($Vm.Name + " 已从拦截区恢复并启用 · 已备份") "#3ECF8E"
    return $true
  }

  $newItem = $Vm.Item.PSObject.Copy()
  if ($Desired) { $newItem.State = "Enabled" } else { $newItem.State = "Disabled" }
  if ($script:CurrentNav -ne "changes" -and $idx -ge 0) {
    $script:ViewVms[$idx] = New-ItemVm $newItem
  }
  for ($i = 0; $i -lt $script:AllItems.Count; $i++) {
    if ($script:AllItems[$i].Id -eq $newItem.Id) { $script:AllItems[$i] = $newItem; break }
  }
  $done = "已禁用"
  if ($Desired) { $done = "已启用" }
  Set-Status ($Vm.Name + " " + $done + " · 已备份") "#3ECF8E"

  # 推荐清单同步刷新（若已生成）
  if ($script:AdvReady) {
    try {
      Build-AdviceRows
      Update-NavCounts $script:AllItems
      Build-Nav
      if ($script:CurrentNav -eq "advice") { Refresh-Advice }
    } catch {}
  }
  return $true
}

# 点击开关（路由事件，覆盖所有行内 CheckBox）
$win.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
  param($s, $e)
  $src = $e.OriginalSource
  $cb = $null
  while ($src) {
    if ($src -is [System.Windows.Controls.CheckBox]) { $cb = $src; break }
    try { $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src) } catch { break }
  }
  if (-not $cb) { return }
  if ($cb.Name) { return }
  $vm = $cb.DataContext
  if (-not $vm -or -not $vm.PSObject.Properties['Item']) { return }

  $desired = [bool]$cb.IsChecked
  if ($desired -eq [bool]$vm.IsOn) { return }

  if (-not $vm.CanToggle) {
    $cb.IsChecked = [bool]$vm.IsOn
    if ($vm.NeedsAdmin) { Set-Status '该项需要管理员权限，请点右上角「以管理员身份重启」' '#E0A93B' }
    else { Set-Status '该项为只读（系统保护或不支持切换）' '#EAEBEB' }
    return
  }

  Apply-Toggle -Vm $vm -Desired $desired -CheckBox $cb
})

# ---------- 详情弹层事件 ----------
# 点击行（非开关区域）打开详情
$ui.ItemsList.Add_PreviewMouseLeftButtonUp({
  param($s, $e)
  if ($ui.DetailOverlay.Visibility -eq "Visible") { return }
  $src = $e.OriginalSource
  $node = $src
  while ($node) {
    if ($node -is [System.Windows.Controls.CheckBox]) { return }
    try { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) } catch { break }
  }
  $lb = $ui.ItemsList
  $vm = $lb.SelectedItem
  if (-not $vm) { return }
  Show-ItemDetail -Vm $vm
})


# 推荐清单里点击行也打开详情（用 AddHandler + handledEventsToo，ListBoxItem 会标记事件已处理）
$advClickHandler = [System.Windows.Input.MouseButtonEventHandler]{
  param($s, $e)
  if ($ui.DetailOverlay.Visibility -eq "Visible") { return }
  $node = $e.OriginalSource
  while ($node) {
    if ($node -is [System.Windows.Controls.CheckBox]) { return }
    try { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) } catch { break }
  }
  $vm = $ui.AdviceList.SelectedItem
  if (-not $vm) { return }
  Show-ItemDetail -Vm $vm
}
$ui.AdviceList.AddHandler([System.Windows.UIElement]::MouseLeftButtonUpEvent, $advClickHandler, $true)

$ui.DetailCloseBtn.Add_Click({ Hide-ItemDetail })

# 点击遮罩空白处关闭
$ui.DetailOverlay.Add_MouseLeftButtonDown({
  param($s, $e)
  if ($e.OriginalSource -eq $ui.DetailOverlay) { Hide-ItemDetail }
})

# 详情里的切换按钮
$ui.DetailToggleBtn.Add_Click({
  $vm = $script:DetailVm
  if (-not $vm) { return }
  $target = -not [bool]$vm.IsOn
  $ok = Apply-Toggle -Vm $vm -Desired $target
  if (-not $ok) {
    $ui.DetailHint.Text = "操作失败：该项需要管理员权限，请点右上角「以管理员身份重启」后再试。"
    Write-SmLog ('详情切换失败: ' + $vm.Item.Id) 'WARN'
    return
  }
  if ($ok) {
    $again = $null
    foreach ($v in $script:ViewVms) { if ($v.Item.Id -eq $vm.Item.Id) { $again = $v; break } }
    if ($again) { Show-ItemDetail -Vm $again } else { Hide-ItemDetail }
  }
})

$win.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq "Escape" -and $ui.DetailOverlay.Visibility -eq "Visible") { Hide-ItemDetail; return }
  if ($e.Key -eq "F5") { Start-Scan; return }
  if ($e.Key -eq "F" -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
    $ui.SearchBox.Focus() | Out-Null
    return
  }
})

# 定时器：轮询后台扫描 + 周期自动同步
$script:Tick = 0
$script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AutoTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:AutoTimer.Add_Tick({
  $script:Tick++
  Finish-Scan
  $interval = [int]$cfg.watchSeconds
  if ($interval -lt 3) { $interval = 3 }
  if ($script:Tick % $interval -eq 0) { Start-Scan -KeepStatus }
})
$script:AutoTimer.Start()

# ---------- 启动 ----------
$win.Add_SourceInitialized({
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $v = 1
    [SmNative]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) | Out-Null
    $v2 = 0x00120000
    [SmNative]::DwmSetWindowAttribute($h, 19, [ref]$v2, 4) | Out-Null
  } catch {}
})

$ui.AdminBadge.Visibility = 'Collapsed'
$ui.ElevateBtn.Visibility = 'Collapsed'
if ($isAdmin) {
  $ui.AdminBadge.Visibility = 'Visible'
} else {
  $ui.ElevateBtn.Visibility = 'Visible'
}
$ui.AutoDisableBox.IsChecked = [bool]$cfg.autoDisableNew
$ui.SetAutoDisableBox.IsChecked = [bool]$cfg.autoDisableNew
$ui.SetShowSystemBox.IsChecked = [bool]$cfg.showSystemItems
try { $ui.SelfStartBox.IsChecked = [bool](Test-SelfStart) } catch {}
try { $ui.SetSelfStartBox.IsChecked = [bool](Test-SelfStart) } catch {}
try { Apply-Theme ([string]$cfg.theme) -NoSave } catch { Write-SmLog ('应用主题失败: ' + $_.Exception.Message) 'WARN' }

Load-Changes
Update-NavCounts @()
Build-Nav
$ui.NavList.SelectedIndex = 0
Refresh-View
$ui.WatcherText.Text = ('监控中 · 每 ' + $cfg.watchSeconds + ' 秒同步一次')
Set-Status '正在初始化…' '#F0B45B'

$win.Add_Loaded({
  Start-Scan
})

$win.Add_Closed({
  try { $script:AutoTimer.Stop() } catch {}
  try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch {}
  try { $script:Pool.Close(); $script:Pool.Dispose() } catch {}
})

$null = $win.ShowDialog()
