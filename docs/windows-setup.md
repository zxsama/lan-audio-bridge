# Windows 一键配置

在 Windows x64 中双击仓库根目录的 [`Setup-Windows-Audio.cmd`](../Setup-Windows-Audio.cmd)，输入 Docker 所在主机的 IPv4 地址。无需预先安装 Voicemeeter、Python、PowerShell 模块或编译工具。

脚本使用 Windows 自带的 PowerShell 5.1，也可由 PowerShell 7 执行。仅支持 **Voicemeeter Standard**；检测到正在运行的 Banana / Potato 时会停止，不替换其会话。

## 首次运行

1. 下载官方 Voicemeeter Standard 1.1.3.0，校验固定 SHA256 和 VB-Audio 发布者签名。
2. 请求管理员权限，调用官方静默安装程序，核验应用版本、发布者签名及 VAIO 驱动注册、版本和状态。
3. 提示重启 Windows。脚本不会自动重启；在同一用户下再次登录后继续配置。
4. 开启驱动原生 Windows 音量控制，配置托盘启动和 VAIO 主输入缓冲；已有安装按需请求一次管理员权限并重启 Voicemeeter。
5. 设置虚拟输入 → BUS B → VBAN，读回参数成功后，将 Windows 的三个默认播放角色切换到 `Voicemeeter Input`。

已安装且可用的 Standard 会直接进入配置。脚本保留已有物理输出设备选择，关闭虚拟输入的 A 路由，将两个硬件输入从 B 总线移出；BUS B 专用于电脑音频。虚拟输入和 B 总线的增益设为 0 dB，并解除这两处静音，不改麦克风默认设备或 Windows 端点音量。

Windows 音量滑块、音量键和静音通过驱动原生选项生效，无需音量同步后台进程。该厂商选项作用于所有 VAIO 播放端点；脚本保留端点当前音量和静音值。音量选项仅修改已核验的控制面板和驱动构建，未知版本会明确停止。

Voicemeeter 使用原生托盘图标，登录时加载配置并隐藏主窗口。脚本为当前 Voicemeeter 进程保留其高精度定时器请求，避免 Windows 11 在窗口不可见时忽略请求；不修改系统电源计划。此策略不是对任意音频卡顿的保证。

VAIO 6 内部缓冲设为 3072 个采样，保留其他 VAIO 和内部时钟缓冲。该值按官方建议为常见最大 1024 采样缓冲保留三倍空间；需要更大应用缓冲或采用其他音频接口时，应重新评估。原生偏好在完整保存会话、正常退出 Voicemeeter 后写入，启动后核验会话参数。

当前支持的安装组合为 Standard 1.1.3.0 与 VAIO 驱动 3.4.1.9。该安装器返回 `1` 的完成路径也可能包含驱动警告，因此脚本只在文件、签名和驱动证据齐全时进入 `PendingReboot`，不会仅凭返回码判断成功。旧脚本误记为 `InstallFailed` 的完整安装会自动恢复续配，不重复安装，也不绕过重启要求。

新版统一驱动提供 8 个播放端点。脚本通过波形接口和父设备识别 Standard 主输入（VAIO 6），备份后禁用其余 7 个播放端点，使常用输出列表只显示 `Voicemeeter Input`。录音端点和物理声卡不受影响，`Restore` 会先恢复本次禁用的端点，再恢复原默认设备。等待首次重启时，如果安装导致默认输出切入 VAIO，脚本会先恢复安装前的可用输出，避免尚未配置时没有声音。

VBAN 使用 48 kHz、双声道、16 位 PCM，默认端口 `6980`、流名 `Windows`。首次配置选择空闲输出槽位，重复配置复用仍属于本项目的槽位，不覆盖其他已启用的输出流。无 A1 物理设备时，Voicemeeter 使用内部时钟。

Docker 必须已启用 `ENABLE_DESKTOP=true`，并将 `VBAN_SOURCE_IP` 设为电脑的局域网 IPv4，端口和流名需一致。脚本只配置 Windows，不修改 NAS、Docker 或防火墙规则。接收端配置见 [Windows 网络音频与混音](desktop-audio.md)。

## 命令行

```powershell
# 以下地址为文档示例，替换为 Docker 主机的 IPv4。
.\scripts\windows-audio.ps1 -Address 192.0.2.20

# 自定义参数；接收端必须同步配置。
.\scripts\windows-audio.ps1 -Address 192.0.2.20 -Port 6980 -StreamName Windows

# 仅展示将写入的参数，不下载、安装或修改音频配置。
.\scripts\windows-audio.ps1 -Action Plan -Address 192.0.2.20

# 只读查看安装路径、端点、默认设备和本地配置。
.\scripts\windows-audio.ps1 -Action Status

# 恢复首次配置前保存的播放设备、混音器配置和本项目启动项。
.\scripts\windows-audio.ps1 -Action Restore
```

默认执行策略阻止直接调用 `.ps1` 时，使用 `.cmd` 启动器；它仅为当前脚本进程指定执行策略，不改全局策略。

## 状态与恢复

配置、XML 备份及日志保存在 `%LOCALAPPDATA%\LanAudioBridge\WindowsAudio`，包含本机地址及设备标识，不应提交到仓库。`driver-volume-original.json`、`tray-original.clixml`、`engine-original.clixml` 分别保存原生选项的首次状态；`runtime-power-*.json` 按进程实例保存临时策略。登录所需脚本复制到该目录，无需保持网络共享盘连接。

首次安装后的 `PendingReboot` 状态不会被视为可播放。登录续配失败时查看 `setup.log`，修正后重新运行启动器。`Status` 是本地状态检查，不代表 UDP 已送达或音响已出声。可以播放一段电脑音频，再从手机投放，确认两路同时播放、分别停止和空闲释放。

路由配置失败时尝试回滚当次混音器配置、默认播放设备、启动项及已保存的启动配置文件；保留 `rollback-*.xml` 便于诊断。驱动和原生偏好为各自可恢复的配置阶段，后续路由失败时这些阶段可能已经完成，可运行 `Restore` 恢复首次快照。XML 恢复会轮询读回保存的参数，避免把异步加载中的旧快照当成已恢复。旧备份没有参数快照时会提示在 Voicemeeter 中核对。

`Restore` 不卸载 Voicemeeter。恢复驱动全局音量选项可能请求管理员权限，恢复托盘和缓冲偏好会正常重启 Voicemeeter。原默认设备缺失时会提示重新连接；已经不存在的辅助 VAIO 端点会跳过，不阻止恢复仍可用的物理输出及启动项。

Windows 默认播放设备切换和播放端点禁用使用系统的 `IPolicyConfig` COM 接口，该接口没有公开的稳定性保证；写入后核验实际状态，失败进入回滚流程。端点识别仅针对已核验的驱动布局，未知端点不会按名称批量禁用。Windows 更新后的兼容性应以实机验证为准。该功能未改变接收端的手机切换和独立电脑混音规则。

## 来源与授权

脚本为项目自有 MIT 代码，通过 [Voicemeeter Remote API](https://download.vb-audio.com/Download_CABLE/VoicemeeterRemoteAPI.pdf) 配置客户端。Voicemeeter 来自 [VB-Audio / voicemeeter.com](https://voicemeeter.com/)，采用 Donationware 授权，欢迎捐赠或购买许可证支持项目；专业使用和分发条件以 [VB-Audio 授权说明](https://vb-audio.com/Services/licensing.htm)为准。

仓库及 Docker 镜像均不捆绑其安装包、驱动或 Remote DLL；安装时直接从官方固定版本地址下载。安装、原生音量和内部时钟行为依据 [Standard 官方手册](https://vb-audio.com/Voicemeeter/Voicemeeter_UserManual.pdf)。原生偏好和音量选项的自动化适配限定已核验的文件哈希，不视为厂商承诺稳定的公开接口。
