#Requires -Version 5.1
<#  Core.ps1 - 自启动管家核心：枚举 / 状态判定 / 开关 / 备份 / 快照  #>

$script:AppRoot = Split-Path -Parent $PSScriptRoot
if (-not $script:AppRoot) { $script:AppRoot = $PSScriptRoot }
$script:AppRoot = [System.IO.Path]::GetFullPath($script:AppRoot)

$script:Paths = @{
  Root     = $script:AppRoot
  State    = Join-Path $script:AppRoot 'state'
  Backup   = Join-Path $script:AppRoot 'backup'
  Logs     = Join-Path $script:AppRoot 'logs'
  Icons    = Join-Path $script:AppRoot 'state\icons'
  Config   = Join-Path $script:AppRoot 'state\config.json'
  Snapshot = Join-Path $script:AppRoot 'state\snapshot.json'
  Changes  = Join-Path $script:AppRoot 'state\changes.jsonl'
}
foreach ($d in @($script:Paths.State, $script:Paths.Backup, $script:Paths.Logs, $script:Paths.Icons)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$script:LogFile = Join-Path $script:Paths.Logs ('sm-' + (Get-Date -Format 'yyyyMMdd') + '.log')

function Write-SmLog {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
}

function Test-SmAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SmConfig {
  $def = [ordered]@{
    watchSeconds      = 5
    autoDisableNew    = $false
    includeServices   = $false
    showSystemItems   = $false
    firstRun          = $true
    ignoreNames       = @()
    theme             = '石墨'
  }
  if (Test-Path $script:Paths.Config) {
    try {
      $raw = Get-Content $script:Paths.Config -Raw -Encoding UTF8 | ConvertFrom-Json
      $keys = @($def.Keys)
      foreach ($k in $keys) {
        if ($raw.PSObject.Properties.Name -contains $k) { $def[$k] = $raw.$k }
      }
    } catch { Write-SmLog ('配置读取失败: ' + $_.Exception.Message) 'WARN' }
  }
  return $def
}

function Save-SmConfig {
  param($Config)
  try { $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $script:Paths.Config -Encoding UTF8 }
  catch { Write-SmLog ('配置保存失败: ' + $_.Exception.Message) 'WARN' }
}

# ---------------- 注册表底座 ----------------
function Get-RegRoot { param([string]$Hive) if ($Hive -eq 'HKCU') { return [Microsoft.Win32.Registry]::CurrentUser } return [Microsoft.Win32.Registry]::LocalMachine }
function Get-RegKey {
  param([string]$Hive, [string]$Path, [bool]$Writable = $false)
  try { return (Get-RegRoot $Hive).OpenSubKey($Path, $Writable) } catch { return $null }
}
function Get-RegValueNames {
  param([string]$Hive, [string]$Path)
  $k = Get-RegKey -Hive $Hive -Path $Path
  if (-not $k) { return @() }
  try { return @($k.GetValueNames() | Where-Object { $_ -ne '' }) } finally { $k.Close() }
}
function Get-RegValue {
  param([string]$Hive, [string]$Path, [string]$Name)
  $k = Get-RegKey -Hive $Hive -Path $Path
  if (-not $k) { return $null }
  try { return $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
  finally { $k.Close() }
}

# ---------------- StartupApproved ----------------
function Get-ApprovalPath {
  param([string]$Hive, [string]$Area)
  if ($Hive -eq 'HKCU') { return 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\' + $Area }
  return 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\' + $Area
}
function Convert-ApprovalBytes {
  param($Bytes)
  if ($null -eq $Bytes) { return @{ State = 'Unknown'; When = $null } }
  # 注册表读回的二进制可能是 Object[]，统一转成 byte[]
  try { $Bytes = [byte[]]$Bytes } catch { return @{ State = 'Unknown'; When = $null } }
  if ($Bytes.Length -lt 4) { return @{ State = 'Unknown'; When = $null } }
  $b0 = $Bytes[0]
  $state = 'Unknown'
  if ($b0 -eq 0x02 -or $b0 -eq 0x06) { $state = 'Enabled' }
  elseif ($b0 -eq 0x01 -or $b0 -eq 0x03 -or $b0 -eq 0x07) { $state = 'Disabled' }
  $when = $null
  if ($Bytes.Length -ge 12) {
    try {
      $ft = [BitConverter]::ToInt64($Bytes, 4)
      if ($ft -gt 0) { $when = [DateTime]::FromFileTimeUtc($ft).ToLocalTime() }
    } catch {}
  }
  return @{ State = $state; When = $when }
}
function Get-Approval {
  param([string]$Hive, [string]$Area, [string]$Name)
  $v = Get-RegValue -Hive $Hive -Path (Get-ApprovalPath $Hive $Area) -Name $Name
  if ($null -eq $v) { return $null }
  return Convert-ApprovalBytes $v
}
function Set-Approval {
  param([string]$Hive, [string]$Area, [string]$Name, [bool]$Enabled)
  $p = Get-ApprovalPath $Hive $Area
  $k = Get-RegKey -Hive $Hive -Path $p -Writable $true
  if (-not $k) {
    $root = Get-RegRoot $Hive
    $k = $root.CreateSubKey($p)
  }
  if (-not $k) { throw '无法写入启动批准表（需要管理员权限）' }
  try {
    $b = New-Object byte[] 12
    if ($Enabled) { $b[0] = 0x02 } else { $b[0] = 0x03 }
    [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($b, 4)
    $k.SetValue($Name, $b, [Microsoft.Win32.RegistryValueKind]::Binary)
  } finally { $k.Close() }
}

# ---------------- 图标与路径 ----------------
$script:IconCache = @{}
function Get-IconPath {
  param([string]$ExePath)
  if ([string]::IsNullOrWhiteSpace($ExePath)) { return $null }
  $key = $ExePath.ToLowerInvariant()
  if ($script:IconCache.ContainsKey($key)) { return $script:IconCache[$key] }
  $script:IconCache[$key] = $null
  try {
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::Unicode.GetBytes($key))).Replace('-', '').Substring(0, 16)
    $png = Join-Path $script:Paths.Icons ($hash + '.png')
    if (-not (Test-Path $png)) {
      Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
      $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
      if (-not $ico) { return $null }
      $ico.ToBitmap().Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
      $ico.Dispose()
    }
    $script:IconCache[$key] = $png
    return $png
  } catch { return $null }
}
function Resolve-ExeFromCommand {
  param([string]$Command)
  if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
  try {
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $path = $null
    if ($c.StartsWith('"')) {
      $end = $c.IndexOf('"', 1)
      if ($end -gt 0) { $path = $c.Substring(1, $end - 1) }
    } else {
      $m = [regex]::Match($c, '^(.*?\.(exe|bat|cmd|com|lnk|vbs|ps1|scr))(?=\s|$)', 'IgnoreCase')
      if ($m.Success) { $path = $m.Groups[1].Value } else { $path = ($c -split ' ')[0] }
    }
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if (Test-Path -LiteralPath $path) { return $path }
    $bare = [System.IO.Path]::GetFileName($path)
    $bases = @($env:ProgramFiles, $env:ProgramFilesX86, $env:SystemRoot, (Join-Path $env:LOCALAPPDATA 'Programs'))
    foreach ($base in $bases) {
      if (-not $base) { continue }
      $cand = Join-Path $base $bare
      if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $path
  } catch { return $null }
}
function Get-PublisherFromExe {
  param([string]$ExePath)
  if ([string]::IsNullOrWhiteSpace($ExePath)) { return '' }
  try {
    if (-not (Test-Path -LiteralPath $ExePath)) { return '' }
    $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
    if ($vi.CompanyName) { return [string]$vi.CompanyName }
  } catch {}
  return ''
}
function Get-FriendlyName {
  param([string]$ExePath, [string]$Fallback)
  try {
    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
      $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
      if ($vi.FileDescription) { return [string]$vi.FileDescription }
      if ($vi.ProductName) { return [string]$vi.ProductName }
    }
  } catch {}
  if ($Fallback) { return $Fallback }
  if ($ExePath) { return [System.IO.Path]::GetFileNameWithoutExtension($ExePath) }
  return '未知项目'
}

function New-StartupItem {
  param([string]$Id, [string]$Name, [string]$Command, [string]$Kind, [string]$Scope,
        [string]$Location, [string]$State, [string]$StateSource, [bool]$Supported,
        [bool]$RequiresAdmin, [bool]$Protected, [string]$Note, $Raw)
  $exe = Resolve-ExeFromCommand $Command
  $exists = $false
  if ($exe) { $exists = Test-Path -LiteralPath $exe -PathType Leaf }
  return [pscustomobject]@{
    Id            = $Id
    Name          = $Name
    Command       = $Command
    Kind          = $Kind
    Scope         = $Scope
    Location      = $Location
    State         = $State
    StateSource   = $StateSource
    Supported     = $Supported
    RequiresAdmin = $RequiresAdmin
    Protected     = $Protected
    ExePath       = $exe
    Exists        = $exists
    Publisher     = (Get-PublisherFromExe $exe)
    IconPath      = (Get-IconPath $exe)
    Note          = $Note
    Raw           = $Raw
  }
}

# ---------------- 枚举：Run / RunOnce ----------------
$script:RunSources = @(
  @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run';     Kind = 'Run';     Area = 'Run';   Scope = 'User' }
  @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'; Kind = 'RunOnce'; Area = 'Run';   Scope = 'User' }
  @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run';     Kind = 'Run';     Area = 'Run';   Scope = 'Machine' }
  @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Kind = 'RunOnce'; Area = 'Run';   Scope = 'Machine' }
  @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     Kind = 'Run';     Area = 'Run32'; Scope = 'Machine' }
  @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Kind = 'RunOnce'; Area = 'Run32'; Scope = 'Machine' }
)
function Get-RunItems {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($src in $script:RunSources) {
    foreach ($name in (Get-RegValueNames -Hive $src.Hive -Path $src.Path)) {
      $cmd = [string](Get-RegValue -Hive $src.Hive -Path $src.Path -Name $name)
      $approval = Get-Approval -Hive $src.Hive -Area $src.Area -Name $name
      $state = 'Enabled'; $source = 'default'; $note = ''
      if ($approval) { $state = $approval.State; $source = 'approved' }
      elseif ($src.Kind -eq 'RunOnce') { $note = '一次性启动项' }
      if ($state -eq 'Unknown') { $state = 'Enabled'; $note = '状态字节异常，按启用处理' }
      $exe = Resolve-ExeFromCommand $cmd
      $protected = $false
      if ($exe) {
        $fn = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        $protected = (($exe -like "$env:SystemRoot\*") -and ($fn -match 'SecurityHealthSystray|ctfmon|RtkAudUService'))
      }
      $items.Add((New-StartupItem -Id ('run|' + $src.Hive + '|' + $src.Area + '|' + $name) -Name $name -Command $cmd -Kind $src.Kind -Scope $src.Scope -Location ($src.Hive + ':\' + $src.Path) -State $state -StateSource $source -Supported $true -RequiresAdmin ($src.Hive -eq 'HKLM') -Protected $protected -Note $note -Raw @{ Hive = $src.Hive; Area = $src.Area; Name = $name }))
    }
  }
  return $items
}

# ---------------- 枚举：启动文件夹 ----------------
function Get-ShortcutTarget {
  param([string]$LnkPath)
  try {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($LnkPath)
    $t = [string]$sc.TargetPath
    if ($sc.Arguments) { $t = $t + ' ' + $sc.Arguments }
    return $t
  } catch { return $null }
}
function Get-StartupFolderItems {
  $items = New-Object System.Collections.Generic.List[object]
  $folders = @(
    @{ Path = [Environment]::GetFolderPath('Startup');       Hive = 'HKCU'; Scope = 'User' }
    @{ Path = [Environment]::GetFolderPath('CommonStartup'); Hive = 'HKLM'; Scope = 'Machine' }
  )
  foreach ($f in $folders) {
    if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue)) {
      $cmd = $null
      if ($file.Extension -ieq '.lnk') { $cmd = Get-ShortcutTarget $file.FullName }
      if (-not $cmd) { $cmd = $file.FullName }
      $approval = Get-Approval -Hive $f.Hive -Area 'StartupFolder' -Name $file.Name
      $state = 'Enabled'; $source = 'default'
      if ($approval) { $state = $approval.State; $source = 'approved' }
      if ($state -eq 'Unknown') { $state = 'Enabled' }
      $items.Add((New-StartupItem -Id ('folder|' + $f.Scope + '|' + $file.Name) -Name ([System.IO.Path]::GetFileNameWithoutExtension($file.Name)) -Command $cmd -Kind 'StartupFolder' -Scope $f.Scope -Location $file.FullName -State $state -StateSource $source -Supported $true -RequiresAdmin ($f.Scope -eq 'Machine') -Protected $false -Note '' -Raw @{ Hive = $f.Hive; Area = 'StartupFolder'; Name = $file.Name; Path = $file.FullName }))
    }
  }
  return $items
}

# ---------------- 枚举：计划任务（登录/开机触发） ----------------
# 计划任务原始清单：优先 COM（Schedule.Service），必要时回退 CIM（Get-ScheduledTask）
# 受限环境（如从编译后的 exe 派生进程）里 CIM 会报「系统找不到指定的路径」，COM 不受影响
function Get-TaskRawList {
  param([switch]$ForceCim)
  $out = New-Object System.Collections.Generic.List[object]
  $viaCom = -not [bool]$ForceCim
  if (-not $viaCom) {
    try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) }
    catch {
      Write-SmLog ('CIM 计划任务枚举失败: ' + $_.Exception.GetType().Name + ' / ' + $_.Exception.Message) 'WARN'
    }
  }
  if (-not $viaCom) {
    foreach ($t in $tasks) {
      $isLogon = $false; $triggerDesc = ''
      foreach ($tr in @($t.Triggers)) {
        if (-not $tr) { continue }
        $cls = [string]$tr.CimClass.CimClassName
        if ($cls -match 'LogonTrigger|BootTrigger') {
          $isLogon = $true
          if (-not $triggerDesc) { if ($cls -match 'Boot') { $triggerDesc = '开机时' } else { $triggerDesc = '登录时' } }
        }
      }
      if (-not $isLogon) { continue }
      $action = ''
      try { $a = $t.Actions | Select-Object -First 1; if ($a) { $action = [string]$a.Execute } } catch {}
      $out.Add([pscustomobject]@{ Path = [string]$t.TaskPath; Name = [string]$t.TaskName; StateText = [string]$t.State; TriggerDesc = $triggerDesc; Action = $action })
    }
    return $out
  }
  try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $stack = New-Object System.Collections.Stack
    $stack.Push($svc.GetFolder('\'))
    while ($stack.Count -gt 0) {
      $folder = $stack.Pop()
      try {
        foreach ($t in $folder.GetTasks(1)) {
          $isLogon = $false; $triggerDesc = ''
          try {
            foreach ($tr in $t.Definition.Triggers) {
              $ty = [int]$tr.Type
              if ($ty -eq 8 -or $ty -eq 9) {
                $isLogon = $true
                if (-not $triggerDesc) { if ($ty -eq 8) { $triggerDesc = '开机时' } else { $triggerDesc = '登录时' } }
              }
            }
          } catch {}
          if (-not $isLogon) { continue }
          $action = ''
          try { $act = $t.Definition.Actions.Item(1); if ($act) { $action = [string]$act.Path } } catch {}
          $st = 'Unknown'
          switch ([int]$t.State) { 3 { $st = 'Ready' } 4 { $st = 'Running' } 1 { $st = 'Disabled' } }
          $full = [string]$t.Path
          $nm = [string]$t.Name
          $pth = $full
          if ($nm -and $full.EndsWith($nm)) { $pth = $full.Substring(0, $full.Length - $nm.Length) }
          $out.Add([pscustomobject]@{ Path = $pth; Name = $nm; StateText = $st; TriggerDesc = $triggerDesc; Action = $action })
        }
      } catch {}
      try { foreach ($sub in $folder.GetFolders(0)) { $stack.Push($sub) } } catch {}
    }
  } catch { Write-SmLog ('COM 计划任务枚举失败: ' + $_.Exception.Message) 'WARN' }
  return $out
}

function Get-TaskItems {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($t in (Get-TaskRawList)) {
    $path = $t.Path
    $isSystem = ($path -like '\Microsoft\Windows\*')
    $state = 'Unknown'
    if ($t.StateText -eq 'Ready' -or $t.StateText -eq 'Running') { $state = 'Enabled' }
    elseif ($t.StateText -eq 'Disabled') { $state = 'Disabled' }
    # 需要管理员：任务文件不在当前用户可写范围内（多数由安装程序以管理员身份创建）
    $needsAdmin = $false
    try {
      $taskFile = (Join-Path (Join-Path $env:SystemRoot 'System32\Tasks') ($path.TrimStart('\') + $t.Name))
      $fs = [System.IO.File]::Open($taskFile, 'Open', 'Write', 'ReadWrite')
      $fs.Close()
    } catch { $needsAdmin = $true }
    $note = $t.TriggerDesc + ' · ' + $t.StateText
    if ($needsAdmin) { $note = $note + ' · 需管理员' }
    $items.Add((New-StartupItem -Id ('task|' + $path + $t.Name) -Name $t.Name -Command $t.Action -Kind 'Task' -Scope 'User' -Location ($path + $t.Name) -State $state -StateSource 'task' -Supported $true -RequiresAdmin $needsAdmin -Protected $isSystem -Note $note -Raw @{ Path = $path; Name = $t.Name; System = $isSystem }))
  }
  return $items
}

# ---------------- 枚举：UWP 启动任务 ----------------
$script:UwpRoot = 'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
function Get-UwpItems {
  $items = New-Object System.Collections.Generic.List[object]
  $rootKey = Get-RegKey -Hive 'HKCU' -Path $script:UwpRoot
  if (-not $rootKey) { return $items }
  try {
    foreach ($pkg in $rootKey.GetSubKeyNames()) {
      $pkgKey = $null
      try { $pkgKey = $rootKey.OpenSubKey($pkg) } catch { continue }
      if (-not $pkgKey) { continue }
      try {
        foreach ($taskName in $pkgKey.GetSubKeyNames()) {
          $taskKey = $null
          try { $taskKey = $pkgKey.OpenSubKey($taskName) } catch { continue }
          if (-not $taskKey) { continue }
          try {
            if ($taskKey.GetValue('State', $null) -eq $null) { continue }
            $v = [int]$taskKey.GetValue('State')
            $state = 'Unknown'
            if ($v -eq 2 -or $v -eq 4) { $state = 'Enabled' }
            elseif ($v -eq 0 -or $v -eq 1 -or $v -eq 3) { $state = 'Disabled' }
            $friendly = $pkg -replace '_[a-z0-9]+$', ''
            $items.Add((New-StartupItem -Id ('uwp|' + $pkg + '|' + $taskName) -Name $taskName -Command $friendly -Kind 'UWP' -Scope 'User' -Location ($friendly + ' / ' + $taskName) -State $state -StateSource 'uwp' -Supported $true -RequiresAdmin $false -Protected $false -Note $friendly -Raw @{ Package = $pkg; Task = $taskName }))
          } finally { $taskKey.Close() }
        }
      } finally { $pkgKey.Close() }
    }
  } finally { $rootKey.Close() }
  return $items
}

# ---------------- 枚举：自动启动服务（只读） ----------------
function Get-ServiceItems {
  $items = New-Object System.Collections.Generic.List[object]
  try { $svcs = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $_.StartMode -eq 'Auto' }) }
  catch { Write-SmLog ('服务枚举失败: ' + $_.Exception.Message) 'WARN'; return $items }
  foreach ($s in $svcs) {
    $exe = [string]$s.PathName
    if ($exe.StartsWith('"')) { $end = $exe.IndexOf('"', 1); if ($end -gt 0) { $exe = $exe.Substring(1, $end - 1) } }
    else { $exe = ($exe -split ' ')[0] }
    $inSystem = $false
    if (-not [string]::IsNullOrWhiteSpace($exe)) { $inSystem = ($exe -like "$env:SystemRoot\*") }
    $items.Add((New-StartupItem -Id ('svc|' + $s.Name) -Name ([string]$s.DisplayName) -Command ([string]$s.PathName) -Kind 'Service' -Scope 'Machine' -Location ('服务 / ' + $s.Name) -State 'Enabled' -StateSource 'service' -Supported $false -RequiresAdmin $true -Protected $inSystem -Note '自动启动服务 · 只读' -Raw @{ ServiceName = $s.Name }))
  }
  return $items
}

# ---------------- 枚举：被联想电脑管家拦截的启动项 ----------------
$script:QuarantineSources = @(
  @{ Hive = 'HKCU'; Parent = 'Software\Microsoft\Windows\CurrentVersion\Run'; SourcePath = 'Software\Microsoft\Windows\CurrentVersion\Run\LenovoDisabled'; Scope = 'User' }
  @{ Hive = 'HKLM'; Parent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; SourcePath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run\LenovoDisabled'; Scope = 'Machine' }
)
function Get-QuarantinedRunItems {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($s in $script:QuarantineSources) {
    foreach ($name in (Get-RegValueNames -Hive $s.Hive -Path $s.SourcePath)) {
      $cmd = [string](Get-RegValue -Hive $s.Hive -Path $s.SourcePath -Name $name)
      if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
      $items.Add((New-StartupItem -Id ('quar|' + $s.Hive + '|' + $name) -Name $name -Command $cmd -Kind 'Quarantine' -Scope $s.Scope -Location ($s.Hive + ':\' + $s.SourcePath) -State 'Disabled' -StateSource 'quarantine' -Supported $true -RequiresAdmin ($s.Hive -eq 'HKLM') -Protected $false -Note '被联想电脑管家拦截' -Raw @{ Hive = $s.Hive; Name = $name; Parent = $s.Parent; SourcePath = $s.SourcePath; Area = 'Run' }))
    }
  }
  return $items
}

# ---------------- 汇总 ----------------
function Get-StartupItems {
  param([switch]$IncludeServices)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $all = New-Object System.Collections.Generic.List[object]
  foreach ($fn in @('Get-RunItems', 'Get-QuarantinedRunItems', 'Get-StartupFolderItems', 'Get-TaskItems', 'Get-UwpItems')) {
    try { $r = & $fn; if ($r) { foreach ($i in $r) { $all.Add($i) } } }
    catch { Write-SmLog ($fn + ' 失败: ' + $_.Exception.Message) 'WARN' }
  }
  if ($IncludeServices) {
    try { foreach ($i in (Get-ServiceItems)) { $all.Add($i) } } catch {}
  }
  # 忽略名单：用户明确不想看到的条目（支持通配符），不进快照、不进变更记录
  try {
    $ign = @((Get-SmConfig).ignoreNames) | Where-Object { $_ }
    if ($ign.Count -gt 0) {
      $kept = New-Object System.Collections.Generic.List[object]
      $skipped = 0
      foreach ($i in $all) {
        $hit = $false
        foreach ($pat in $ign) { if ([string]$i.Name -like $pat) { $hit = $true; break } }
        if ($hit) { $skipped++ } else { $kept.Add($i) }
      }
      if ($skipped -gt 0) { Write-SmLog ('忽略名单过滤 ' + $skipped + ' 项') 'INFO' }
      $all = $kept
    }
  } catch {}
  $sw.Stop()
  Write-SmLog ('扫描完成: ' + $all.Count + ' 项, ' + $sw.ElapsedMilliseconds + 'ms')
  return $all
}

# ---------------- 开关 ----------------
function Backup-StartupItem {
  param($Item, [string]$Action)
  try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rec = [ordered]@{ time = (Get-Date).ToString('o'); action = $Action; id = $Item.Id; name = $Item.Name; kind = $Item.Kind; command = $Item.Command; location = $Item.Location; state = $Item.State; raw = $Item.Raw }
    $file = Join-Path $script:Paths.Backup ($stamp + '-' + $Item.Kind + '.jsonl')
    ($rec | ConvertTo-Json -Depth 5 -Compress) | Add-Content -Path $file -Encoding UTF8
    return $file
  } catch { Write-SmLog ('备份失败: ' + $_.Exception.Message) 'WARN'; return $null }
}

function Set-StartupItemState {
  param($Item, [bool]$Enabled)
  $act = 'disable'
  if ($Enabled) { $act = 'enable' }
  $backupFile = Backup-StartupItem -Item $Item -Action $act
  try {
    if ($Item.Kind -eq 'Run' -or $Item.Kind -eq 'RunOnce' -or $Item.Kind -eq 'StartupFolder') {
      Set-Approval -Hive $Item.Raw.Hive -Area $Item.Raw.Area -Name $Item.Raw.Name -Enabled $Enabled
    } elseif ($Item.Kind -eq 'Task') {
      if ($Enabled) { Enable-ScheduledTask -TaskPath $Item.Raw.Path -TaskName $Item.Raw.Name -ErrorAction Stop | Out-Null }
      else { Disable-ScheduledTask -TaskPath $Item.Raw.Path -TaskName $Item.Raw.Name -ErrorAction Stop | Out-Null }
    } elseif ($Item.Kind -eq 'Quarantine') {
      # 拦截区本身被联想的安全驱动写保护（SetValue 报 data area too small），
      # 只能把值重新写回 Run，由联想弹窗让用户选择「允许」。
      if (-not $Enabled) { throw '该项已被联想电脑管家拦截，无需再次禁用' }
      $val = [string](Get-RegValue -Hive $Item.Raw.Hive -Path $Item.Raw.SourcePath -Name $Item.Raw.Name)
      if ([string]::IsNullOrWhiteSpace($val)) { throw '拦截区里找不到该启动项' }
      $parent = Get-RegKey -Hive $Item.Raw.Hive -Path $Item.Raw.Parent -Writable $true
      if (-not $parent) { throw '无法写入启动项主键' }
      try { $parent.SetValue($Item.Raw.Name, $val, [Microsoft.Win32.RegistryValueKind]::String) } finally { $parent.Close() }
      Set-Approval -Hive $Item.Raw.Hive -Area 'Run' -Name $Item.Raw.Name -Enabled $true
    } elseif ($Item.Kind -eq 'UWP') {
      $p = $script:UwpRoot + '\' + $Item.Raw.Package + '\' + $Item.Raw.Task
      $k = Get-RegKey -Hive 'HKCU' -Path $p -Writable $true
      if (-not $k) { throw '无法打开 UWP 启动任务键' }
      $val = 0
      if ($Enabled) { $val = 2 }
      try { $k.SetValue('State', [int]$val, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
    } else { throw ('不支持的类型: ' + $Item.Kind) }
    $word = '禁用'
    if ($Enabled) { $word = '启用' }
    Write-SmLog (('{0} -> {1} [{2}]' -f $Item.Name, $word, $Item.Kind))
    return @{ Ok = $true; Backup = $backupFile; Error = $null }
  } catch {
    $msg = $_.Exception.Message
    Write-SmLog ('切换失败 ' + $Item.Name + ': ' + $msg) 'ERROR'
    return @{ Ok = $false; Backup = $backupFile; Error = $msg }
  }
}

# ---------------- 快照 / 变更 ----------------
function Get-Snapshot {
  param($Items)
  $map = [ordered]@{}
  foreach ($i in $Items) {
    $map[$i.Id] = [ordered]@{ name = $i.Name; state = $i.State; kind = $i.Kind; command = $i.Command; exists = $i.Exists }
  }
  return $map
}
function Save-Snapshot {
  param($Snapshot)
  try { $Snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $script:Paths.Snapshot -Encoding UTF8 }
  catch { Write-SmLog ('快照保存失败: ' + $_.Exception.Message) 'WARN' }
}
function Read-PreviousSnapshot {
  if (-not (Test-Path $script:Paths.Snapshot)) { return $null }
  try {
    $raw = Get-Content $script:Paths.Snapshot -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = [ordered]@{}
    foreach ($p in $raw.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
  } catch { return $null }
}
function Compare-Snapshot {
  param($Old, $New)
  $changes = New-Object System.Collections.Generic.List[object]
  if (-not $Old) { return $changes }
  foreach ($id in @($New.Keys)) {
    if (-not $Old.Contains($id)) { $changes.Add([pscustomobject]@{ Type = 'added'; Id = $id; Name = $New[$id].name; Kind = $New[$id].kind; Detail = '新发现自启动项' }) }
    elseif ($Old[$id].state -ne $New[$id].state) { $changes.Add([pscustomobject]@{ Type = 'state'; Id = $id; Name = $New[$id].name; Kind = $New[$id].kind; Detail = ([string]$Old[$id].state + ' → ' + [string]$New[$id].state) }) }
    elseif ($Old[$id].command -ne $New[$id].command) { $changes.Add([pscustomobject]@{ Type = 'changed'; Id = $id; Name = $New[$id].name; Kind = $New[$id].kind; Detail = '启动命令已变更' }) }
  }
  foreach ($id in @($Old.Keys)) {
    if (-not $New.Contains($id)) { $changes.Add([pscustomobject]@{ Type = 'removed'; Id = $id; Name = $Old[$id].name; Kind = $Old[$id].kind; Detail = '已卸载或移除' }) }
  }
  return $changes
}
function Add-ChangeLog {
  param($Changes)
  if (-not $Changes) { return }
  foreach ($c in $Changes) {
    $rec = [ordered]@{ time = (Get-Date).ToString('o'); type = $c.Type; id = $c.Id; name = $c.Name; kind = $c.Kind; detail = $c.Detail }
    try { ($rec | ConvertTo-Json -Compress) | Add-Content -Path $script:Paths.Changes -Encoding UTF8 } catch {}
  }
}
function Get-RecentChanges {
  param([int]$Count = 80)
  if (-not (Test-Path $script:Paths.Changes)) { return @() }
  try {
    $out = @()
    foreach ($l in (Get-Content $script:Paths.Changes -Tail $Count -Encoding UTF8)) { try { $out += ($l | ConvertFrom-Json) } catch {} }
    return $out
  } catch { return @() }
}

# ---------------- 自检 ----------------
function Test-SmEnvironment {
  $r = [ordered]@{ Admin = (Test-SmAdmin); CanWriteUser = $false; Errors = @() }
  try {
    $probe = Join-Path $script:Paths.State 'write-test.bin'
    [System.IO.File]::WriteAllText($probe, 'ok')
    $r.CanWriteUser = (Test-Path $probe)
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
  } catch { $r.Errors += ('目录不可写: ' + $_.Exception.Message) }
  return $r
}

# ---------------- 本程序的登录自启 ----------------
# 在当前用户启动文件夹放一个指向 启动.vbs 的快捷方式；wscript 启动可保证无黑窗口。
function Get-SelfStartShortcutPath {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) '自启动管家.lnk')
}

function Test-SelfStart {
  try { return (Test-Path -LiteralPath (Get-SelfStartShortcutPath)) } catch { return $false }
}

function Set-SelfStart {
  param([bool]$Enabled, [string]$AppDir)
  $lnk = Get-SelfStartShortcutPath
  if ($Enabled) {
    if (-not $AppDir) { throw '缺少程序目录，无法创建自启快捷方式' }
    $exe = Join-Path $AppDir '自启动管家.exe'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    if (Test-Path -LiteralPath $exe) {
      $sc.TargetPath = $exe
      $sc.Arguments = ''
    } else {
      $vbs = Join-Path $AppDir '启动.vbs'
      if (-not (Test-Path -LiteralPath $vbs)) { throw ('找不到启动脚本: ' + $vbs) }
      $sc.TargetPath = 'wscript.exe'
      $sc.Arguments = '"' + $vbs + '"'
    }
    $sc.WorkingDirectory = $AppDir
    $sc.Description = '自启动管家 - 开机监控自启动项'
    $sc.Save()
    return $true
  }
  if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
  # 顺手清掉批准表里的记录，避免下次再打开时被旧的「已禁用」状态干扰
  try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' -Name '自启动管家.lnk' -Force -ErrorAction SilentlyContinue } catch {}
  return $false
}
