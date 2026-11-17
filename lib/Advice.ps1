#Requires -Version 5.1
<#  Advice.ps1 - 应用说明与禁用建议知识库（自启动管家）  #>

$script:AdviceCache = @{}

# 匹配键：Match 用正则，匹配 "<名称>|<exe文件名>|<发布者>" 的小写形式
$script:AdviceKb = @(
  @{ Match = 'securityhealth|windows security'; App = 'Windows 安全中心'; Verdict = 'keep';
     Purpose = 'Windows 自带的杀毒与防火墙托盘程序。它在后台常驻，负责实时防护、病毒库更新和威胁拦截提醒。';
     Why = '这是系统安全组件的入口，禁用它不会关掉防护本身，但会让安全状态不可见、威胁提醒被吞掉，出问题时更难察觉。';
     DisPros = @(); DisCons = @('托盘图标消失，病毒库更新失败或拦截到威胁时你看不到提示', 'Windows 安全中心页面会提示「需要你的注意」，反而更吵');
     KeepPros = @('实时防护状态一眼可见'); KeepCons = @('托盘常驻约占几 MB 内存，启动耗时几乎可忽略') }

  @{ Match = 'rtkauduservice|realtek'; App = 'Realtek 音频驱动服务'; Verdict = 'keep';
     Purpose = 'Realtek 声卡驱动的后台服务，负责耳机插拔检测、音频接口切换（前后面板自动识别）等硬件级功能。';
     Why = '它属于硬件驱动配套组件。禁用后耳机插拔可能不再自动切换输出设备，严重时声音直接不动。';
     DisPros = @('省下约 20~40MB 内存'); DisCons = @('耳机/音箱插拔无法自动切换，需要手动选设备', '部分机器会出现无声或爆音');
     KeepPros = @('音频设备插拔即时响应'); KeepCons = @('常驻内存，但这是驱动服务，占用固定') }

  @{ Match = 'motionpro|mpinit|array networks'; App = 'Array Networks MotionPro VPN'; Verdict = 'caution';
     Purpose = '公司/学校内网 VPN 客户端。启动时注册虚拟网卡与隧道组件，让你能访问内网资源。';
     Why = '如果你每天要连内网办公，别禁；只在家里偶尔用就禁掉，手动开客户端同样能连。';
     DisPros = @('开机不再自动挂 VPN，需要自己双击客户端'); DisCons = @('内网资源（OA、共享盘、内网站点）连不上，直到手动启动');
     KeepPros = @('开机即在内网，远程办公无感'); KeepCons = @('VPN 常驻会一直占用隧道，可能拖慢普通上网') }

  @{ Match = 'awesun|oray|向日葵'; App = '向日葵远程控制 AweSun'; Verdict = 'caution';
     Purpose = '远程桌面/远程协助工具。开机自启是为了让你随时能从别的设备连回这台电脑。';
     Why = '取决于你是否需要「随时被远程连接」。长期不用就从开机启动里去掉，需要时手动开即可，功能不受影响。';
     DisPros = @('少一个长期在线的网络监听端口，降低被扫描到的风险', '省内存与一点带宽'); DisCons = @('无法再从外部随时远程连回本机');
     KeepPros = @('随时可被远程协助，出问题能救急'); KeepCons = @('常驻后台联网，有轻微安全隐患') }

  @{ Match = 'tailscale'; App = 'Tailscale 组网'; Verdict = 'caution';
     Purpose = '基于 WireGuard 的虚拟局域网工具。开机自启后，你的几台设备之间随时能互相访问。';
     Why = '这是需要常驻才有意义的网络工具——不常驻就等于没有组网。只有确实不用它时才禁。';
     DisPros = @('省一点内存和一块虚拟网卡'); DisCons = @('其他设备立刻连不上这台机器，跨设备同步/远程全断');
     KeepPros = @('设备间随时互通，无感远程'); KeepCons = @('常驻联网，属于后台网络服务') }

  @{ Match = 'snipaste'; App = 'Snipaste 截图工具'; Verdict = 'free';
     Purpose = '截图与贴图工具。开机自启是为了随时按快捷键截图，不用每次先找图标。';
     Why = '纯工具类软件，禁掉只影响「快捷键能否直接截图」，不影响系统。用得频繁就留着。';
     DisPros = @('省下约 15~30MB 内存'); DisCons = @('按快捷键没反应，得先手动打开 Snipaste');
     KeepPros = @('随时截图，习惯不被打断'); KeepCons = @('常驻托盘') }

  @{ Match = 'jianying|剪映'; App = '剪映 JianyingPro'; Verdict = 'recommend';
     Purpose = '视频剪辑软件的托盘常驻程序，用于检测素材、加速启动和后台更新。';
     Why = '剪辑软件没必要开机就跑。禁掉后双击图标照样能用，只是首次启动慢一两秒。';
     DisPros = @('省下 100~300MB 内存和明显的一次开机耗时'); DisCons = @('第一次打开剪映会慢 1~3 秒');
     KeepPros = @('点开即用'); KeepCons = @('常年占用内存，实际多数时间闲置') }

  @{ Match = 'qykernel|iqiyi|爱奇艺|hcdnclient'; App = '爱奇艺客户端 HCDN'; Verdict = 'recommend';
     Purpose = '爱奇艺视频客户端及其 P2P/CDN 后台进程（会在后台为其他用户分发视频分片，占用上传带宽）。';
     Why = '视频客户端的开机自启几乎全是「预加载 + 后台分发」，对你有用的只有启动快一点。禁掉收益明显。';
     DisPros = @('不再后台上传带宽，看剧时网速更稳', '省 150~400MB 内存'); DisCons = @('打开爱奇艺慢一两秒');
     KeepPros = @('客户端启动略快'); KeepCons = @('后台上传占带宽，可能影响游戏和下载') }

  @{ Match = 'workbuddy'; App = 'WorkBuddy 桌面 AI 工作台'; Verdict = 'caution';
     Purpose = '腾讯桌面 AI 工作台。开机自启是为了让它随时待命。';
     Why = '这是你日常在用的工具。禁掉不影响功能，但每次开机要手动打开。按使用频率决定。';
     DisPros = @('省内存，开机更干净'); DisCons = @('开机后要手动启动，第一次响应慢');
     KeepPros = @('开工即用'); KeepCons = @('常驻内存') }

  @{ Match = 'deskbox'; App = 'DeskBox 桌面整理'; Verdict = 'caution';
     Purpose = '桌面图标整理/美化工具，开机自启以恢复你的桌面布局。';
     Why = '如果它负责你的桌面分组布局，禁掉后桌面会回到未整理状态；只是偶尔用就可以禁。';
     DisPros = @('少一个常驻进程'); DisCons = @('桌面图标恢复系统默认排列，整理盒消失');
     KeepPros = @('桌面布局每次开机都一样'); KeepCons = @('常驻内存') }

  @{ Match = 'onedrive'; App = 'OneDrive 云同步'; Verdict = 'caution';
     Purpose = '微软云盘客户端。开机自启后自动把本地文件夹同步到云端，并显示同步状态。';
     Why = '如果依赖它备份文件，必须保留；如果只是登着账号不用，禁掉能省不少内存和磁盘 IO。';
     DisPros = @('省 100~200MB 内存和开机磁盘 IO'); DisCons = @('文件不再自动同步，改动可能丢失云端版本');
     KeepPros = @('文件自动备份，换机即恢复'); KeepCons = @('持续占用内存与网络') }

  @{ Match = 'onenote'; App = 'OneNote 笔记'; Verdict = 'free';
     Purpose = '微软笔记软件的快速捕获入口（「发送至 OneNote」）。开机自启只为随时剪藏内容。';
     Why = '不常用剪藏功能就可以禁，OneNote 本身照常打开。';
     DisPros = @('少一个 Office 进程'); DisCons = @('剪藏快捷方式失效，需先开 OneNote');
     KeepPros = @('随手剪藏'); KeepCons = @('Office 后台进程常驻') }

  @{ Match = 'office|actionserver'; App = 'Microsoft Office 维护任务'; Verdict = 'caution';
     Purpose = 'Office 的后台维护计划任务，负责更新检查、组件修复、许可证刷新等。';
     Why = '它不是你能感知的功能，但停掉可能导致 Office 更新失败或激活异常。收益很小，不建议动。';
     DisPros = @('少一个后台任务'); DisCons = @('Office 更新与自修复可能失效，长期可能出激活/组件问题');
     KeepPros = @('Office 保持最新且自愈'); KeepCons = @('偶发后台占用') }

  @{ Match = 'qianwen|通义|tongyi'; App = '通义千问更新器'; Verdict = 'recommend';
     Purpose = '通义千问客户端的自动更新检查程序，只负责下载安装新版本。';
     Why = '更新器不需要开机启动，它只在打开应用时才需要工作，常驻纯属浪费。';
     DisPros = @('开机少一个联网进程', '不再被静默升级'); DisCons = @('不会自动更新，需要手动检查');
     KeepPros = @('始终最新'); KeepCons = @('开机自启 + 定时联网') }

  @{ Match = 'quark|夸克'; App = '夸克网盘更新器'; Verdict = 'recommend';
     Purpose = '夸克客户端的自动更新组件，负责静默升级。';
     Why = '典型的「只为更新而常驻」，禁用后软件照常用。';
     DisPros = @('减少开机自启项与联网', '避免被静默安装新版本'); DisCons = @('需要手动更新');
     KeepPros = @('自动保持最新'); KeepCons = @('常驻且检查频繁') }

  @{ Match = 'googleupdater|googlechromeautolaunch|chrome'; App = 'Google Chrome'; Verdict = 'recommend';
     Purpose = 'Chrome 的开机预加载与更新任务，让浏览器启动更快并保持版本最新。';
     Why = '预加载对 SSD 机器收益极小，但会常驻多个进程。禁用后 Chrome 首次打开稍慢，功能不变。';
     DisPros = @('开机少 2~4 个 Google 进程，内存立省 100MB+'); DisCons = @('Chrome 首次启动慢约 1 秒，更新需手动');
     KeepPros = @('浏览器秒开'); KeepCons = @('常驻内存明显') }

  @{ Match = 'douyintray|douyin|抖音'; App = '抖音客户端'; Verdict = 'recommend';
     Purpose = '抖音 PC 客户端的托盘常驻程序，用于接收通知和快速启动。';
     Why = '短视频客户端没有开机自启的必要，禁掉不影响观看。';
     DisPros = @('少一个常驻进程和后台推送'); DisCons = @('打开抖音慢一两秒');
     KeepPros = @('托盘消息即时'); KeepCons = @('后台常驻消耗资源') }

  @{ Match = 'cloudmusic|网易云'; App = '网易云音乐'; Verdict = 'free';
     Purpose = '音乐客户端的托盘常驻，用于桌面歌词、全局快捷键和快速唤起。';
     Why = '除非你开机就要听歌并用全局快捷键，否则可以禁。';
     DisPros = @('省 100~200MB 内存'); DisCons = @('全局媒体快捷键和桌面歌词要等手动启动后生效');
     KeepPros = @('随时按快捷键控制播放'); KeepCons = @('常驻内存偏大') }

  @{ Match = 'weixin|wechat|微信'; App = '微信'; Verdict = 'caution';
     Purpose = '微信 PC 端。开机自启让你一开机就能收到消息。';
     Why = '看使用习惯。电脑是主要通信端就留着；只是偶尔登录就禁掉，能省下不小内存。';
     DisPros = @('省 300~600MB 内存', '减少开机卡顿'); DisCons = @('开机后收不到消息提醒，直到手动打开');
     KeepPros = @('消息不中断'); KeepCons = @('内存占用最大的常驻软件之一') }

  @{ Match = 'qqnt'; App = 'QQ（NT 架构）'; Verdict = 'caution';
     Purpose = 'QQ 桌面客户端。开机自启用于接收消息与文件。';
     Why = '按是否把它当主力通信工具决定。禁掉只影响开机后主动收消息。';
     DisPros = @('省 200~400MB 内存'); DisCons = @('开机后需手动启动才能收消息');
     KeepPros = @('消息即时'); KeepCons = @('常驻内存较大') }

  @{ Match = 'baiduyun|baidu'; App = '百度网盘'; Verdict = 'recommend';
     Purpose = '网盘的检测与同步组件，用于监控同步文件夹、维持上传下载。';
     Why = '网盘常驻组件争议最大：既占内存又常年后台上传。除非在做持续同步，否则建议禁。';
     DisPros = @('停止后台上传与磁盘扫描，机器明显更轻', '省 200MB+ 内存'); DisCons = @('自动同步暂停，需手动启动');
     KeepPros = @('文件夹持续同步'); KeepCons = @('长期后台上传与磁盘 IO') }

  @{ Match = 'thunder|迅雷'; App = '迅雷'; Verdict = 'recommend';
     Purpose = '下载工具的常驻与后台加速组件。';
     Why = '下载工具不需要开机常驻，要下载时再开即可。';
     DisPros = @('避免后台上传/做种占带宽', '省内存'); DisCons = @('打开迅雷慢一点');
     KeepPros = @('后台下载任务继续'); KeepCons = @('闲置时仍占资源') }

  @{ Match = 'kook'; App = 'KOOK 语音'; Verdict = 'free';
     Purpose = '游戏语音软件的常驻程序，用于随时接收语音邀请和好友消息。';
     Why = '不打游戏/不语音时禁掉即可。';
     DisPros = @('省内存与后台联网'); DisCons = @('语音来电提醒需要手动开客户端');
     KeepPros = @('随时被拉进语音'); KeepCons = @('常驻内存') }

  @{ Match = 'doubao'; App = '豆包 AI 客户端'; Verdict = 'free';
     Purpose = '字节豆包桌面端的托盘常驻，用于快捷唤起。';
     Why = 'AI 客户端随用随开即可，没必要常驻。';
     DisPros = @('省内存'); DisCons = @('全局快捷键唤起失效');
     KeepPros = @('随时唤起'); KeepCons = @('常驻内存') }

  @{ Match = 'jetbrains'; App = 'JetBrains Toolbox'; Verdict = 'free';
     Purpose = 'JetBrains 全家桶的版本管理器，常驻用于自动更新 IDE 和快速打开项目。';
     Why = '开发者工具。禁掉后 IDE 照常用，只是不再自动更新。';
     DisPros = @('省 100MB 左右内存'); DisCons = @('IDE 更新需手动，托盘快捷入口消失');
     KeepPros = @('IDE 自动更新'); KeepCons = @('常驻内存') }

  @{ Match = 'mumu'; App = 'MuMu 模拟器服务'; Verdict = 'recommend';
     Purpose = '网易 MuMu 安卓模拟器的后台服务，用于加速模拟器启动和管理虚拟化。';
     Why = '模拟器服务会持续占内存甚至占用虚拟化资源。只有天天用模拟器才值得常驻。';
     DisPros = @('释放 200MB+ 内存与虚拟化占用'); DisCons = @('模拟器首次启动变慢');
     KeepPros = @('模拟器秒开'); KeepCons = @('可能与 Hyper-V/WSL 抢资源') }

  @{ Match = 'daemon tools'; App = 'DAEMON Tools Lite'; Verdict = 'free';
     Purpose = '虚拟光驱工具，开机自启用于自动挂载镜像。';
     Why = '不常挂镜像就禁掉，需要时手动开。';
     DisPros = @('少一个驱动级常驻'); DisCons = @('已挂载的虚拟盘开机后需重新挂载');
     KeepPros = @('虚拟盘常驻'); KeepCons = @('驱动常驻') }

  @{ Match = 'nvidia'; App = 'NVIDIA Broadcast / 显卡组件'; Verdict = 'caution';
     Purpose = 'N 卡配套的 AI 音视频增强（降噪、虚拟背景）与驱动辅助进程。';
     Why = '如果你开直播/开会用它的降噪，留着；不用就禁，能省显存和内存。';
     DisPros = @('省显存与内存'); DisCons = @('麦克风降噪、虚拟摄像头不可用');
     KeepPros = @('会议/直播音质好'); KeepCons = @('占用 GPU 资源') }

  @{ Match = 'razer|rzappengine'; App = '雷蛇 Razer 外设服务'; Verdict = 'free';
     Purpose = '雷蛇键鼠/耳机的灯效与宏引擎，开机自启以应用你的配置。';
     Why = '不在意灯效和宏就可以禁，硬件功能不受影响。';
     DisPros = @('省 100~200MB 内存'); DisCons = @('自定义灯效、宏、DPI 配置不生效');
     KeepPros = @('外设配置随开机生效'); KeepCons = @('常驻内存，常与反作弊冲突') }

  @{ Match = 'mchose'; App = 'MCHOSE 键鼠驱动'; Verdict = 'free';
     Purpose = '迈从外设的配置监控程序，用于保持灯效与按键映射。';
     Why = '只用默认配置的话可以禁。';
     DisPros = @('少一个常驻'); DisCons = @('自定义灯效/宏失效');
     KeepPros = @('外设配置生效'); KeepCons = @('常驻') }

  @{ Match = 'zoogvpn'; App = 'ZoogVPN'; Verdict = 'caution';
     Purpose = 'VPN 客户端，开机自启用于自动连接。';
     Why = '需要开机即连就留，否则禁掉，手动连一样用。';
     DisPros = @('不自动连接，减少后台流量'); DisCons = @('开机后网络不走代理');
     KeepPros = @('开机即代理'); KeepCons = @('常驻联网') }

  @{ Match = 'avast'; App = 'Avast 相关组件'; Verdict = 'caution';
     Purpose = 'Avast 杀毒/浏览器的启动项与自更新组件。';
     Why = '如果 Avast 是主力杀软，浏览器组件可以禁，但杀毒主服务别动。';
     DisPros = @('减少一个浏览器启动器'); DisCons = @('Avast 浏览器不再自动开，杀软本体不受影响');
     KeepPros = @('安全组件齐全'); KeepCons = @('多一层常驻') }

  @{ Match = 'ds-harness|deepseek harness'; App = 'DSH 桌面端'; Verdict = 'caution';
     Purpose = 'DeepSeek Harness 桌面客户端，你现在正在用的这个工具的开机自启。';
     Why = '取决于你是否希望开机就绪。禁掉只是要手动启动。';
     DisPros = @('开机更快'); DisCons = @('开机后要手动开 DSH');
     KeepPros = @('开机即用'); KeepCons = @('常驻内存') }

  @{ Match = 'fevergames'; App = 'FeverGames 安装器'; Verdict = 'recommend';
     Purpose = '游戏平台的安装/更新器，通常只在下游戏时用一次。';
     Why = '安装器属于典型的「用完就该删」的启动项。';
     DisPros = @('去掉一个几乎无用的常驻项'); DisCons = @('不会有游戏更新提示');
     KeepPros = @('自动更新游戏'); KeepCons = @('常驻且多为广告推送') }

  @{ Match = 'cxstudyinhouse|学习通|chaoxing'; App = '学习通客户端'; Verdict = 'free';
     Purpose = '超星学习通 PC 客户端（Electron 应用），开机自启用于接收课程通知。';
     Why = '不需要开机就收通知的话可以禁。';
     DisPros = @('省 150MB+ 内存（Electron 应用偏重）'); DisCons = @('课程提醒需手动开客户端');
     KeepPros = @('通知即时'); KeepCons = @('Electron 常驻内存大') }

  @{ Match = 'fluentflyout'; App = 'FluentFlyout 音量浮窗'; Verdict = 'free';
     Purpose = '第三方音量/媒体控制浮窗工具（Windows 11 风格）。';
     Why = '属于美化类小工具，不需要就禁。';
     DisPros = @('少一个常驻'); DisCons = @('音量调节时不显示浮窗');
     KeepPros = @('音量提示好看'); KeepCons = @('常驻内存') }

  @{ Match = 'xrite'; App = 'X-Rite 校色工具'; Verdict = 'caution';
     Purpose = '显示器校色仪配套软件，开机自启用于加载你保存的色彩配置文件（ICC）。';
     Why = '如果你校过色并依赖这个 ICC，禁掉后颜色会回到未校准状态。';
     DisPros = @('少一个常驻'); DisCons = @('开机后不再套用校准色彩，修图/看片偏色');
     KeepPros = @('颜色准确'); KeepCons = @('常驻内存') }

  @{ Match = 'powerautomate|autostarttask'; App = 'Power Automate Desktop'; Verdict = 'caution';
     Purpose = '微软 RPA 工具，开机自启用于运行你设置的自动化流程。';
     Why = '有流程依赖开机触发就留着，否则禁。';
     DisPros = @('省内存'); DisCons = @('开机触发的自动化流程不会执行');
     KeepPros = @('自动化随时可用'); KeepCons = @('常驻且较重') }

  @{ Match = 'launchdouyinguard|douyin_guard'; App = '抖音守护进程'; Verdict = 'recommend';
     Purpose = '抖音客户端的守护/保活进程，用于保活和后台推送。';
     Why = '「守护」类进程只为保活，对你没有直接价值。';
     DisPros = @('去掉一个保活进程'); DisCons = @('抖音启动略慢');
     KeepPros = @('保活'); KeepCons = @('多余常驻') }

  @{ Match = 'calendartask|calendar'; App = '日历任务'; Verdict = 'free';
     Purpose = '日历/日程类应用的开机任务，用于启动时检查日程提醒。';
     Why = '不依赖桌面日程提醒就可以禁。';
     DisPros = @('少一个任务'); DisCons = @('日程提醒可能延后');
     KeepPros = @('日程即时提醒'); KeepCons = @('常驻') }

  @{ Match = 'autotidy|watch\.ps1'; App = '工作区文件自动整理脚本'; Verdict = 'keep';
     Purpose = '你自己写的 PowerShell 脚本：监视工作目录根目录，把散落文件按规则归类到对应目录。';
     Why = '这是你的生产力脚本，禁掉后文件不再自动归类，根目录会乱。';
     DisPros = @('极小的内存占用'); DisCons = @('丢失文件自动归类，需要手动执行 tidy.ps1');
     KeepPros = @('丢文件即归类，工作区保持整洁'); KeepCons = @('一个隐藏的 powershell 进程常驻') }

  @{ Match = 'focus|焦点'; App = 'Windows 焦点自动修复'; Verdict = 'keep';
     Purpose = '你自己写的 vbs 脚本：修复 Windows 窗口焦点被抢占的问题。';
     Why = '这是你为解决实际痛点做的补丁，禁掉后焦点问题会复发。';
     DisPros = @('少一个 wscript 进程'); DisCons = @('窗口焦点被抢占的问题重新出现');
     KeepPros = @('焦点稳定'); KeepCons = @('几乎无开销') }

  @{ Match = 'launcherrsruntime'; App = '运行时启动器任务'; Verdict = 'caution';
     Purpose = '某个应用附带的运行时启动器，用于拉起主程序。';
     Why = '不确定归属时先别禁——它可能是某个软件正常工作的必要环节。可以先禁一次看是否影响使用。';
     DisPros = @('少一个未知任务'); DisCons = @('可能影响对应软件启动');
     KeepPros = @('保证软件正常'); KeepCons = @('来源不明的常驻') }
)


# ============ 建议等级元数据 ============
function Get-AdviceVerdictMeta {
  param([string]$Verdict)
  switch ($Verdict) {
    'keep'      { return @{ Key='keep';      Label='不建议禁用'; Hex='#3ECF8E'; Desc='禁用后可能影响系统或你正在用的功能' } }
    'caution'   { return @{ Key='caution';   Label='看你用不用'; Hex='#E0A93B'; Desc='看你实际使用频率，不用就可以关' } }
    'free'      { return @{ Key='free';      Label='可以禁用';   Hex='#6EA8FE'; Desc='禁掉基本没影响，用时手动打开即可' } }
    'recommend' { return @{ Key='recommend'; Label='建议禁用';   Hex='#F2833B'; Desc='常驻收益低，禁用能明显减轻开机负担' } }
    default     { return @{ Key='caution';   Label='看你用不用'; Hex='#E0A93B'; Desc='信息不足，建议先观察' } }
  }
}

function Get-SafeText {
  param($Value, [string]$Fallback = '—')
  if ($null -eq $Value) { return $Fallback }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { return $Fallback }
  return $s.Trim()
}

function Format-Bytes {
  param([long]$Bytes)
  if ($Bytes -le 0) { return '—' }
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
  return ('{0} B' -f $Bytes)
}

# ============ 事实采集（技术详情） ============
function Get-ItemFacts {
  param($Item)
  $facts = New-Object System.Collections.ArrayList
  function AddF([string]$K, [string]$V) { $null = $facts.Add([pscustomobject]@{ Key = $K; Value = $V }) }

  $kindLabel = switch ([string]$Item.Kind) {
    'Run'           { '注册表启动项（Run）' }
    'RunOnce'       { '一次性启动项（RunOnce）' }
    'StartupFolder' { '启动文件夹快捷方式' }
    'Task'          { '计划任务' }
    'UWP'           { '商店应用启动任务' }
    'Service'       { 'Windows 服务' }
    'Quarantine'    { '被联想电脑管家拦截' }
    default         { [string]$Item.Kind }
  }
  AddF '类型' $kindLabel

  $scope = if ([string]$Item.Hive -eq 'HKLM' -or [string]$Item.Scope -eq 'Machine') { '系统级（所有用户）' }
           elseif ([string]$Item.Scope -eq 'User' -or [string]$Item.Hive -eq 'HKCU') { '当前用户' }
           else { Get-SafeText $Item.Scope }
  AddF '作用域' $scope

  $stateText = if ([string]$Item.State -eq 'Enabled') { '已启用' }
               elseif ([string]$Item.State -eq 'Disabled') { '已禁用' }
               else { Get-SafeText $Item.State }
  AddF '当前状态' $stateText

  $exe = [string]$Item.ExePath
  if ([string]::IsNullOrWhiteSpace($exe)) { $exe = [string]$Item.Path }

  if (-not [string]::IsNullOrWhiteSpace($exe)) {
    AddF '程序路径' $exe
    try {
      $fi = Get-Item -LiteralPath $exe -ErrorAction Stop
      AddF '文件大小' (Format-Bytes ([long]$fi.Length))
      AddF '修改时间' ($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
      $vi = $fi.VersionInfo
      if ($vi -and -not [string]::IsNullOrWhiteSpace($vi.FileVersion)) { AddF '版本' ([string]$vi.FileVersion) }
      if ($vi -and -not [string]::IsNullOrWhiteSpace($vi.CompanyName)) { AddF '发布者' ([string]$vi.CompanyName) }
      if ($vi -and -not [string]::IsNullOrWhiteSpace($vi.FileDescription)) { AddF '文件描述' ([string]$vi.FileDescription) }
      # 数字签名
      try {
        $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
        if ($sig) {
          $sigText = switch ([string]$sig.Status) {
            'Valid' { '已签名 · ' + ([string]$sig.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1') }
            'NotSigned' { '未签名' }
            default { '签名异常（' + [string]$sig.Status + '）' }
          }
          AddF '数字签名' $sigText
        }
      } catch { AddF '数字签名' '无法读取' }
      # 是否在运行
      try {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
          try { $_.Path -and ($_.Path -eq $exe) } catch { $false }
        }).Count
        if ($running -gt 0) { AddF '当前进程' ('运行中 · ' + $running + ' 个进程') } else { AddF '当前进程' '未运行' }
      } catch { }
    } catch {
      AddF '文件状态' '文件不存在（可能已卸载，残留启动项）'
    }
  } else {
    AddF '程序路径' '—'
  }

  $cmd = [string]$Item.Command
  if (-not [string]::IsNullOrWhiteSpace($cmd)) { AddF '启动命令' $cmd }
  $loc = [string]$Item.Location
  if (-not [string]::IsNullOrWhiteSpace($loc)) { AddF '所在位置' $loc }
  $note = [string]$Item.Note
  if (-not [string]::IsNullOrWhiteSpace($note)) { AddF '备注' $note }

  return $facts
}

# ============ 通用推断（知识库未命中时） ============
function Get-GenericAdvice {
  param($Item, [string]$Hay)

  $exe = [string]$Item.ExePath
  if ([string]::IsNullOrWhiteSpace($exe)) { $exe = [string]$Item.Path }
  $kind = [string]$Item.Kind
  $name = Get-SafeText $Item.Name '该项'
  $exists = $true
  if (-not [string]::IsNullOrWhiteSpace($exe)) { $exists = Test-Path -LiteralPath $exe }

  $verdict = 'caution'
  $why = ''
  $purpose = ''

  switch ($kind) {
    'Quarantine' {
      $verdict = 'free'
      $purpose = '这个启动项已被联想电脑管家从开机启动列表中移出（搬到隐藏的「拦截区」），当前不会随开机运行。'
      $why = '它现在本来就没有在跑。如果你根本不需要这个软件开机启动，保持现状即可；需要的话再打开开关恢复到 Run 键。'
    }
    'Service' {
      $verdict = 'keep'
      $purpose = '这是一项 Windows 系统服务，在系统启动阶段由服务控制管理器拉起，通常为硬件、网络或安全组件提供支撑。'
      $why = '服务不是普通的「登录自启」。很多服务被关掉后系统会静默降级（比如网络共享、打印、声音失效），且本程序对服务只做只读展示。'
    }
    'Task' {
      $verdict = 'caution'
      $purpose = '这是一个计划任务，由 Windows 任务计划程序在开机或登录时触发，常见于软件的后台维护、更新检查和定时同步。'
      $why = '计划任务多数不是你的日常功能，但停掉可能导致软件更新或后台同步失败。建议先确认它属于哪个软件再决定。'
    }
    'UWP' {
      $verdict = 'caution'
      $purpose = '这是微软商店应用的启动任务。商店应用被设计为「需要时才运行」，启动任务一般在登录时预加载一次。'
      $why = '商店应用本身可随时从开始菜单打开，禁掉启动任务通常只影响首次启动速度。'
    }
    default {
      if ($exe -match '^[A-Za-z]:\\Windows\\' -or $exe -match '^[A-Za-z]:\\Program Files') {
        $verdict = 'caution'
        $purpose = '这是一个随登录启动的程序，安装在系统目录或 Program Files 下，通常是正式安装的商业/系统级软件。'
        $why = '正式安装的软件一般有对应的常驻需求（托盘、驱动、同步）。不确定用途时建议先保留，观察一段时间再说。'
      } elseif ($exe -match '\\AppData\\Local\\' -or $exe -match '\\AppData\\Roaming\\') {
        $verdict = 'free'
        $purpose = '这是一个随登录启动的程序，安装在用户目录（AppData）下，多为单用户安装的应用或其更新/辅助组件。'
        $why = '装在 AppData 下的自启动项有相当比例是更新器、辅助进程或预加载器，禁掉一般不影响主程序手动使用。'
      } else {
        $verdict = 'caution'
        $purpose = '这是一个随登录启动的程序。它在登录后自动运行，具体作用需要看它的启动命令和所在目录判断。'
        $why = '信息不足，无法确定它是否必要。建议保留先观察；若你确认不需要该软件开机启动，可以关掉试试。'
      }
    }
  }

  # 更新器类提升为建议禁用
  if ($Hay -match 'updater|update|upgrade|installer|bootstrapper|setup|helper') {
    if ($verdict -ne 'keep') {
      $verdict = 'recommend'
      $why = '名称里带 updater/installer/helper 等字样，这类常驻通常只负责检查更新或辅助启动，主程序并不依赖它常驻。'
      if ([string]::IsNullOrWhiteSpace($purpose)) {
        $purpose = '这是某个软件的更新或辅助组件，在后台检查新版本、静默升级或为启动主程序做准备。'
      }
    }
  }

  # 文件已不存在 → 残留项
  if (-not $exists) {
    $verdict = 'free'
    $why = '它指向的程序文件已经不存在了（多半是软件卸载后残留的启动项）。这类项禁掉完全无风险，也可以直接删掉。'
    if ([string]::IsNullOrWhiteSpace($purpose)) {
      $purpose = '这是一个残留的启动项，它原本要启动的程序已不在磁盘上。'
    }
  }

  $disPros = @()
  $disCons = @()
  $keepPros = @()
  $keepCons = @()

  if ($verdict -eq 'recommend' -or $verdict -eq 'free') {
    $disPros = @('减少一个开机常驻进程，开机更快', '少一份后台内存与联网占用')
    $disCons = @('需要时得手动打开对应软件')
    $keepPros = @('随时可用，无需手动启动')
    $keepCons = @('长期占用内存，且多数时间闲置')
  } elseif ($verdict -eq 'keep') {
    $disPros = @('省下一点内存')
    $disCons = @('依赖它的功能会失效或降级，且往往不易察觉')
    $keepPros = @('系统/软件按设计正常工作')
    $keepCons = @('占用固定资源')
  } else {
    $disPros = @('开机更干净，少一个后台进程')
    $disCons = @('该软件的开机自动行为（提醒、同步、托盘）会停止')
    $keepPros = @('相关功能随开机就绪')
    $keepCons = @('常驻资源占用')
  }

  return [pscustomobject]@{
    App = $name
    Verdict = $verdict
    Matched = $false
    Purpose = $purpose
    Why = $why
    DisPros = $disPros
    DisCons = $disCons
    KeepPros = $keepPros
    KeepCons = $keepCons
  }
}

# ============ 主入口：取一条启动项的完整说明 ============
function Get-ItemAdvice {
  # -SkipFacts 用于批量扫描：跳过数字签名/进程探测等慢操作
  param($Item, [switch]$SkipFacts)

  if ($null -eq $Item) { return $null }

  $name = Get-SafeText $Item.Name '未知项'
  $key = [string]$Item.Id
  if ([string]::IsNullOrWhiteSpace($key)) { $key = $name }
  if ($script:AdviceCache.ContainsKey($key)) {
    $cached = $script:AdviceCache[$key]
    if ($SkipFacts) { $cached.Facts = @() } else { $cached.Facts = @(Get-ItemFacts $Item) }
    return $cached
  }

  # 构造匹配串：名称 + exe 文件名 + 发布者
  $exe = [string]$Item.ExePath
  if ([string]::IsNullOrWhiteSpace($exe)) { $exe = [string]$Item.Path }
  $exeName = ''
  if (-not [string]::IsNullOrWhiteSpace($exe)) {
    try { $exeName = [System.IO.Path]::GetFileNameWithoutExtension($exe) } catch { }
  }
  $publisher = ''
  if (-not [string]::IsNullOrWhiteSpace($exe) -and (Test-Path -LiteralPath $exe)) {
    try { $publisher = [string](Get-Item -LiteralPath $exe).VersionInfo.CompanyName } catch { }
  }
  $hay = (@($name, $exe, $exeName, $publisher, [string]$Item.Command) -join '|').ToLower()

  $hit = $null
  foreach ($entry in $script:AdviceKb) {
    try {
      if ($hay -match $entry.Match) { $hit = $entry; break }
    } catch { }
  }

  if ($hit) {
    $advice = [pscustomobject]@{
      App = $hit.App
      Verdict = $hit.Verdict
      Matched = $true
      Purpose = $hit.Purpose
      Why = $hit.Why
      DisPros = @($hit.DisPros)
      DisCons = @($hit.DisCons)
      KeepPros = @($hit.KeepPros)
      KeepCons = @($hit.KeepCons)
    }
  } else {
    $advice = Get-GenericAdvice -Item $Item -Hay $hay
  }

  $meta = Get-AdviceVerdictMeta $advice.Verdict

  $result = [pscustomobject]@{
    Name = $name
    App = $advice.App
    Matched = $advice.Matched
    Verdict = $advice.Verdict
    VerdictLabel = $meta.Label
    VerdictHex = $meta.Hex
    VerdictDesc = $meta.Desc
    Purpose = $advice.Purpose
    Why = $advice.Why
    DisPros = @($advice.DisPros | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    DisCons = @($advice.DisCons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    KeepPros = @($advice.KeepPros | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    KeepCons = @($advice.KeepCons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    # 事实每次重算：切换开关后「当前状态 / 当前进程」必须反映最新
    Facts = $(if ($SkipFacts) { @() } else { @(Get-ItemFacts $Item) })
    CanToggle = [bool]$Item.Supported
    Note = [string]$Item.Note
  }

  # 只缓存文字建议，不缓存事实
  $script:AdviceCache[$key] = $result
  return $result
}
