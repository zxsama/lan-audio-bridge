# Windows 一键配置

在 Windows x64 中双击仓库根目录的 [`Setup-Windows-Audio.cmd`](../Setup-Windows-Audio.cmd)，输入 Docker 所在主机的 IPv4 地址。无需预先安装 Voicemeeter、Python、PowerShell 模块或编译工具。

脚本使用 Windows 自带的 PowerShell 5.1，也可由 PowerShell 7 执行。仅支持 **Voicemeeter Standard**；检测到正在运行的 Banana / Potato 时会停止，不替换其会话。

## 首次运行

1. 下载官方 Voicemeeter Standard 1.1.3.0，校验固定 SHA256 和 VB-Audio 发布者签名。
2. 请求管理员权限，调用官方静默安装程序。
3. 提示重启 Windows。脚本不会自动重启；在同一用户下再次登录后继续配置。
4. 设置虚拟输入 → BUS B → VBAN，读回参数成功后，将 Windows 的三个默认播放角色切换到 `Voicemeeter Input`。

已安装且可用的 Standard 会直接进入配置。脚本保留已有物理输出设备选择，关闭虚拟输入的 A 路由，将两个硬件输入从 B 总线移出；BUS B 专用于电脑音频。虚拟输入和 B 总线的增益设为 0 dB，并解除这两处静音，不改麦克风默认设备或 Windows 端点音量。

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

配置、XML 备份和 `setup.log` 保存在 `%LOCALAPPDATA%\LanAudioBridge\WindowsAudio`，包含本机地址及设备标识，不应提交到仓库。登录启动所需脚本复制到该目录，无需保持网络共享盘连接。

首次安装后的 `PendingReboot` 状态不会被视为可播放。登录续配失败时查看 `setup.log`，修正后重新运行启动器。`Status` 是本地状态检查，不代表 UDP 已送达或音响已出声。可以播放一段电脑音频，再从手机投放，确认两路同时播放、分别停止和空闲释放。

配置失败时尝试回滚当次混音器配置、默认播放设备、启动项及已保存的启动配置文件；保留 `rollback-*.xml` 便于诊断。恢复需要原播放设备处于可用状态。`Restore` 不卸载 Voicemeeter，原默认设备缺失时会提示重新连接；混音器 XML 通过官方加载接口提交，实际效果可在 Voicemeeter 中核对。

Windows 默认播放设备切换使用系统的 `IPolicyConfig` COM 接口，该接口没有公开的稳定性保证；失败会进入回滚流程。Windows 更新后的兼容性应以实机验证为准。该功能未改变接收端的手机切换和独立电脑混音规则。

## 来源与授权

脚本为项目自有 MIT 代码，通过 [Voicemeeter Remote API](https://download.vb-audio.com/Download_CABLE/VoicemeeterRemoteAPI.pdf) 配置客户端。Voicemeeter 来自 [VB-Audio / voicemeeter.com](https://voicemeeter.com/)，采用 Donationware 授权，欢迎捐赠或购买许可证支持项目；专业使用和分发条件以 [VB-Audio 授权说明](https://vb-audio.com/Services/licensing.htm)为准。

仓库及 Docker 镜像均不捆绑其安装包、驱动或 Remote DLL；安装时直接从官方固定版本地址下载。安装及内部时钟行为依据 [Standard 官方手册](https://vb-audio.com/Voicemeeter/Voicemeeter_UserManual.pdf)。
