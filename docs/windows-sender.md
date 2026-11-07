# Windows 原生低延迟发送端

`vban-sender.exe` 用 WASAPI loopback 采集 Windows 默认播放设备的混音，逐个采集包立即以 VBAN（48 kHz / 双声道 / PCM16）发往 NAS。它替代 Voicemeeter 的网络输出，不需要虚拟声卡，也不经过 Voicemeeter 内部缓冲。NAS 端使用现有的 VBAN 接收配置，源地址和流名不变。

## 为什么不用 Voicemeeter

2026-11-07 在同一台 PC 上用同一 QPC 时钟测量“应用提交 → UDP 发出”：

| 路径 | 中位数 | P95 |
| --- | ---: | ---: |
| WASAPI → Voicemeeter VAIO → VBAN（最低已测配置） | 45.0 ms | 48.8 ms |
| VAIO 端点 loopback | 61–104 ms | — |
| 原生发送端，10 ms 引擎（厂商驱动的 HDMI / Realtek） | 20.0 ms | 20.1 ms |
| 原生发送端，336 帧引擎（Realtek 改用系统 USB Audio 2.0 驱动） | 7.1 ms | 14.2 ms |
| 原生发送端，128 帧引擎（HDMI 改用系统 HD Audio 驱动） | 2.7 ms | 5.4 ms |

后三行为低延迟测试应用（IAudioClient3、队列不超过一个周期）。普通应用自身保留约 22 ms 播放队列时，结果约为 20–21 ms，主要是应用自己的缓冲。VAIO 的 loopback 位于其内部缓冲之后，因此任何经过 Voicemeeter 的路径都无法低于约 45 ms。

## 工作方式

- **引擎周期**：Windows 共享模式引擎按所有客户端请求的最小周期运行。发送端在被采集的端点上保持一个静音 IAudioClient3 流（keeper），请求驱动支持的最小周期，使所有应用的混音拉取和 loopback 包都变小。只支持 480 帧（10 ms）的驱动无法受益；`--list` 显示每个端点的 `min_frames`。
- **无额外队列**：每个 loopback 包立即拆分为不超过 128 帧的 VBAN 包发送；发送端没有环形缓冲。
- **音量**：loopback 位于软件端点音量/静音之后、硬件音量/静音之前。发送端读取 `QueryHardwareSupport`，只补上由硬件实现的部分，因此 Windows 音量和静音在各类设备上行为一致，不会重复衰减。
- **静音**：持续 2 s 的数字静音后停止发包，NAS 按原有空闲逻辑释放输出。
- **设备变化**：跟随默认播放设备；设备失效时自动重开。`--prefer` 给出有序的首选端点：首选端点重新出现时切回；默认设备消失、Windows 改选非首选设备时换成下一个首选端点；用户在首选设备仍在时手动选择的其他设备会被保留。
- **优先级**：采集线程注册 MMCSS “Pro Audio”。

## 驱动建议

想达到 10 ms 级别，被采集的端点必须支持小于 480 帧的引擎周期。厂商驱动常常只支持 10 ms。本机实测：

| 设备 | 厂商驱动 | Microsoft 系统驱动 |
| --- | --- | --- |
| NVIDIA HDMI/DP 音频 | 480 帧 | `hdaudio.inf`：128 帧 |
| Realtek USB Audio（主板） | 480 帧 | `usbaudio2.inf`：336 帧 |

HDMI/DP 音频端点在显示器休眠或关闭时会消失，因此建议把它作为首选、把常在的设备作为后备。更换驱动需要管理员权限，可在设备管理器中“回退驱动程序”或重新安装厂商驱动恢复。被采集的设备本身是否出声与网络播放无关；需要静音本地输出时，请选择未连接扬声器的输出。

## 安装

在仓库根目录运行 `Setup-Windows-LowLatency.cmd`，或：

```powershell
./scripts/windows-sender.ps1 -Action Setup -Address 192.168.1.20
./scripts/windows-sender.ps1 -Action Setup -Address 192.168.1.20 -Prefer '{HDMI 端点 ID},{常在端点 ID}'
./scripts/windows-sender.ps1 -Action Status
./scripts/windows-sender.ps1 -Action Restore
```

未指定 `-Prefer` 时按最小引擎周期自动选择，排除 Voicemeeter、虚拟声卡和蓝牙端点。Setup 会：

1. 将 `vban-sender.exe` 复制到 `%LOCALAPPDATA%\LanAudioBridge\Sender\`，写入 `sender.conf`；
2. 首次运行时备份默认播放设备、两个启动项和 Voicemeeter 的 VBAN 开关到 `original.json`；
3. 移除 Voicemeeter 方案的登录启动项，关闭正在运行的 Voicemeeter 的 VBAN 输出（同一源地址和流名只能有一路）；
4. 添加 `LanAudioBridgeSender` 登录启动项并立即在后台启动，检查采集已开始。

`Restore` 停止发送端，恢复原启动项、默认播放设备和 VBAN 开关；Voicemeeter 本身不会被卸载。之后再次运行 `Setup-Windows-Audio.cmd` 会重新启用 Voicemeeter 方案，两者不要同时使用。

发送端可执行文件不提交到 Git；用 `native\windows\build.cmd`（需要 MSVC x64）构建到 `dist\windows\`，或使用发布包中的 `scripts\windows\vban-sender.exe`。日志 `sender.log` 只记录事件与计数，超过 1 MiB 时重新开始。

## 命令行

```text
vban-sender --target IPv4 [--port 6980] [--stream Windows] [--device ENDPOINT_ID]
            [--prefer ENDPOINT_ID ...] [--frames 128] [--idle-ms 2000]
            [--no-endpoint-volume] [--no-keeper] [--stats-ms 0] [--log FILE]
vban-sender --config FILE    # 每行一个参数
vban-sender --list           # 每个活动播放端点一行 JSON
vban-sender --stop           # 让正在运行的实例正常退出
```

## 限制

- 端到端延迟仍包含应用自身的播放队列、NAS 接收与输出缓冲、DAC 和扬声器。发送端只能把 Windows 侧降到驱动允许的引擎周期。
- 仅支持 48 kHz；混音格式不同时由 Windows 转换。
- VBAN 不加密、不认证，只在可信局域网使用。
