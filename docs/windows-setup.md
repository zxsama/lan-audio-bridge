# Windows 一键配置

在 Windows x64 中双击仓库根目录的 [`Setup-Windows-Audio.cmd`](../Setup-Windows-Audio.cmd)，输入 NAS 的 IPv4 地址即可。之后 Windows 声音设置中会出现 **“NAS 音频”**，选择它播放即发往 NAS；登录后自动在后台运行。需要管理员权限的步骤会弹出一次 Windows 确认。

```bat
Setup-Windows-Audio.cmd              :: 配置（重复运行会复用已保存的地址和设备）
Setup-Windows-Audio.cmd Status       :: 查看状态
Setup-Windows-Audio.cmd Restore      :: 撤销全部改动
Setup-Windows-Audio.cmd Stop | Start :: 临时停止 / 启动发送端
```

PowerShell 中可传参数，例如 `./scripts/windows-audio.ps1 -Address 192.168.1.20 -Drivers Yes -Prefer '{主端点 ID},{备用端点 ID}' -Name 'NAS 音频'`。`-Drivers Ask|Yes|No` 决定是否更换驱动，默认询问。脚本支持 Windows PowerShell 5.1 与 PowerShell 7。

## 配置内容

1. **低延迟驱动**：列出当前有活动输出、且能换用 Microsoft 类驱动获得更小引擎周期的设备，确认后更换。规则只覆盖 HDMI/DP 显示音频（NVIDIA、AMD、Intel，改用 `hdaudio.inf`）和 USB Audio 2.0 设备（改用 `usbaudio2.inf`）；原厂驱动包记录在案，`Restore` 时装回。
2. **选择输出**：按最小引擎周期选取主输出，排除 Voicemeeter、虚拟声卡和蓝牙。主输出是显示器音频时（显示器休眠会消失），备用输出取一个常在的非显示器设备。重复运行时沿用上次的选择，也可用 `-Prefer` 指定。
3. **清晰命名**：把主、备用输出的设备描述改为“NAS 音频”和“NAS 音频（备用）”，原名称记录在案。
4. **停用旧方案**：关闭正在运行的 Voicemeeter 的 VBAN 输出并结束其进程，移除旧版 Voicemeeter 配置脚本的登录启动项和 `%LOCALAPPDATA%\LanAudioBridge\WindowsAudio`，隐藏 Voicemeeter 的播放和录音端点。默认麦克风若是 Voicemeeter（停止后只会录到静音），改为第一个非蓝牙的真实麦克风。Voicemeeter 本身不会被卸载，不再需要时可在“应用”中卸载。
5. **发送端**：复制 `vban-sender.exe` 到 `%LOCALAPPDATA%\LanAudioBridge\Sender\`，写入 `sender.conf`，添加 `LanAudioBridgeSender` 登录启动项，立即在后台启动并确认采集已开始。

首次运行时备份默认播放设备、启动项与 Voicemeeter 的 VBAN 开关到 `original.json`；之后的每项改动（驱动、名称、隐藏的端点）都追加记录。`Restore` 按记录恢复：先改回名称，再装回原厂驱动，显示被隐藏的端点，恢复仍存在的默认设备，重新启动原先运行的 Voicemeeter，并删除发送端文件。中途失败时保留记录，可再次运行 `Restore`；配置中途失败时会用上一份配置重新启动发送端。

## 发送端

`vban-sender.exe` 用 WASAPI loopback 采集默认播放设备的混音，逐个采集包立即以 VBAN（48 kHz / 双声道 / PCM16）发往 NAS，没有额外缓冲。

- **引擎周期**：Windows 共享模式引擎按所有客户端请求的最小周期运行。发送端在被采集的端点上保持一个静音 IAudioClient3 流，请求驱动支持的最小周期，所有应用随之受益。
- **音量**：loopback 位于软件端点音量/静音之后、硬件音量/静音之前；发送端按 `QueryHardwareSupport` 只补上硬件实现的部分，Windows 音量和静音在各类设备上表现一致。
- **保持连接**：配置写入 `--idle-ms 0`，选择 NAS 输出期间持续发送（含静音），NAS 配合 `DESKTOP_KEEP_AWAKE` 让 DAC 一直保持唤醒，播放前不再有唤醒噪声；关机或切到其他输出后停止发送，NAS 在 `OUTPUT_IDLE_SUSPEND_MS` 后让 DAC 休眠。约 1.6 Mbit/s。
- **音量一致**：“NAS 音频”与“NAS 音频（备用）”共用一个音量和静音状态。调节其中任一个（音量滑块或静音），另一个立即跟随；备用设备重新出现时（如显示器唤醒）按最近的共同音量对齐。可用 `--no-volume-sync` 关闭。
- **仅 NAS 输出**：默认输出不是“NAS 音频”时（例如切到耳机），发送端待机，不采集也不发送。
- **设备变化**：跟随默认播放设备，设备失效时自动重开。首选端点重新出现时切回；默认设备消失后 Windows 改选了非首选设备时，换成下一个首选端点；首选设备仍在时用户手动选择的其他设备会被保留。
- **优先级**：采集线程注册 MMCSS “Pro Audio”。

```text
vban-sender --target IPv4 [--port 6980] [--stream Windows] [--device ENDPOINT_ID]
            [--prefer ENDPOINT_ID ...] [--frames 128] [--idle-ms 2000|0]
            [--no-endpoint-volume] [--no-keeper] [--no-volume-sync] [--stats-ms 0] [--log FILE]
vban-sender --config FILE    # 每行一个参数
vban-sender --list           # 每个活动播放端点一行 JSON，含 min_frames
vban-sender --stop           # 让正在运行的实例正常退出
```

可执行文件不提交到 Git：用 `native\windows\build.cmd`（MSVC x64）构建到 `dist\windows\`，或使用发布包中的 `scripts\windows\vban-sender.exe`。日志 `sender.log` 只记录事件与计数，超过 1 MiB 时重新开始。

## 实测（2026-11-07）

同一 QPC 时钟测得“应用提交 → VBAN 发出”，每组 40 个标记：

| 路径 | 低延迟应用 中位数 / P95 | 普通应用（约 22 ms 自身队列） |
| --- | ---: | ---: |
| 旧方案：WASAPI → Voicemeeter VAIO → VBAN | 45.0 / 48.8 ms | 60–66 ms |
| 原厂驱动，480 帧引擎 | 20.0 / 20.1 ms | 30.0 ms |
| Realtek USB，系统 USB Audio 2.0 驱动，336 帧 | 7.1 / 14.2 ms | 21.0 / 28.0 ms |
| NVIDIA HDMI，系统 HD Audio 驱动，128 帧 | 2.7 / 5.4 ms | 21.4 ms |

VAIO 的 loopback 位于其内部缓冲之后（实测滞后 61–104 ms），因此经过 Voicemeeter 的路径都无法低于约 45 ms。10 ms 引擎下 20 ms 的下限正好是两个周期，只能靠更小的引擎周期降低。普通应用剩余的约 20 ms 是应用自己的播放缓冲。

## 限制

- 端到端延迟还包括 NAS 接收与输出缓冲、DAC 和扬声器，见[延迟验证](latency.md)。
- 显示器音频端点在显示器休眠或关闭时消失，此时自动使用备用输出。
- 设备描述保存在 Windows 端点属性中；更换驱动或重装声卡后端点会变化，重新运行配置即可。
- 仅支持 48 kHz；混音格式不同时由 Windows 转换。VBAN 不加密、不认证，只在可信局域网使用。
- 其他 VBAN 发送端（例如 Voicemeeter）仍可手动使用，格式要求见[电脑音频说明](desktop-audio.md)；同一源地址和流名同时只能有一路。
