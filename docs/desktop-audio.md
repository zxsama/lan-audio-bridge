# Windows 网络音频与混音

VBAN 接收器将电脑声音作为独立输入，与当前手机音源同时播放。AirPlay、DLNA、Spotify 和 MiPlay 之间仍按原规则切换；电脑输入不参与手机会话的抢占。

## Docker 配置

在 `.env` 中启用接收并填写发送电脑的局域网 IPv4 地址：

```dotenv
ENABLE_DESKTOP=true
VBAN_SOURCE_IP=192.0.2.10
VBAN_PORT=6980
VBAN_STREAM_NAME=Windows
DESKTOP_BUFFER_MS=50
DESKTOP_PLAYER_MS=30
DESKTOP_JITTER_MS=20
DESKTOP_VOLUME=100
DESKTOP_IDLE_MS=500
```

`192.0.2.10` 是文档示例，必须替换。建议为发送电脑保留 DHCP 地址。接收端只接受匹配源地址、流名的 UDP 音频；VBAN 本身不提供身份认证或加密，应仅在可信局域网开放端口。生产 Compose 使用 host 网络，无需另加端口映射。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `ENABLE_DESKTOP` | `false` | 启用独立电脑输入 |
| `VBAN_SOURCE_IP` | 空 | 启用时必填，发送电脑的 IPv4 地址 |
| `VBAN_PORT` | `6980` | UDP 接收端口 |
| `VBAN_STREAM_NAME` | `Windows` | 精确匹配的流名，最多 16 UTF-8 字节 |
| `DESKTOP_BUFFER_MS` | `50` | 电脑输出路由的目标缓冲，20–500 ms |
| `DESKTOP_PLAYER_MS` | `30` | 电脑 PCM 播放客户端的目标缓冲，5–200 ms |
| `DESKTOP_JITTER_MS` | `20` | 首次播放前的接收缓冲，5–200 ms |
| `DESKTOP_VOLUME` | `100` | 电脑输入音量，0–100 |
| `DESKTOP_IDLE_MS` | `500` | 连续数字静音或断流后的空闲等待，200–5000 ms |

当前接收格式为 **48 kHz、双声道、16 位有符号小端 PCM**。其他采样率、位深、声道数，以及 VBAN TEXT、MIDI、控制命令均不接收。此接口每次接收一台电脑的一条流。

## Windows 设置

双击仓库根目录的 [`Setup-Windows-Audio.cmd`](../Setup-Windows-Audio.cmd)，输入 NAS 的 IPv4 地址。脚本自动安装并配置 [Voicemeeter Standard](https://vb-audio.com/Voicemeeter/)，将 Windows 默认播放设备切换到虚拟输入，并配置登录启动。首次安装需要管理员确认和一次 Windows 重启；脚本会在重启登录后继续配置，不自动重启电脑。

脚本适用于 Windows x64、Windows PowerShell 5.1 或 PowerShell 7。安装包固定为官方 1.1.3.0，并验证归档、安装程序 SHA256 和发布者签名。状态检查、恢复及完整行为见 [Windows 配置脚本](windows-setup.md)。已有 Banana / Potato 会话不会被自动切换。

也可手动设置：

1. Windows 系统或目标应用的输出设备选择 `Voicemeeter Input (VB-Audio Voicemeeter VAIO)`。
2. 在 Virtual Input 条带打开 **B**、关闭 **A**，确保条带和 BUS B 未静音。
3. 仅网络输出时，A1 可不选物理设备，使用 Internal Clock；主采样率设为 48000 Hz。
4. 打开 VBAN，在 Outgoing Stream 中选择 `BUS B`，填 NAS 地址、端口 `6980` 和流名 `Windows`，设置 `48000 Hz / 2 channels / PCM 16 bits`。
5. 开启该发送行和 VBAN 总开关。其他格式、名称或源地址与接收配置不符时不会播放。

Standard 的总线名称是 BUS B；Windows 的 `Voicemeeter Out B1` 是录音端点，不能替代上述播放设备。配置与内部时钟行为依据[官方手册](https://vb-audio.com/Voicemeeter/Voicemeeter_UserManual.pdf)。Voicemeeter 使用其自身的 Donationware 授权。

## 混音与空闲行为

电脑和手机各保留一条输出路由。任一路暂停、断开或重连，不会停止另一条路由；手机切换协议只替换手机路由。MiPlay 的手机音量仍只控制 MiPlay 输入。

单路播放保持原有增益；两路同时播放时，各路自动预留约 6.02 dB 的混音余量，降低满幅叠加造成的削顶。公共 `OUTPUT_VOLUME` 仍是总输出音量。电脑音量可由 Windows、Voicemeeter 或 `DESKTOP_VOLUME` 调整。

接收端在首次有效声音到达时请求桌面路由，并等待路由就绪后提交音频，以保留短提示音。连续全零样本或断流达到空闲等待时间并等待下游缓冲排空后释放电脑播放器；低音量但非零的声音不会因门限检测被裁掉。双方都停止后才挂起公共输出，任一方恢复即唤醒。持续非零噪声会保持电脑输入活动。

## 延迟与验证

电脑路由使用独立缓冲，不改变 `DLNA_BUFFER_MS` 和手机 `OUTPUT_BUFFER_MS`。配置值仅是软件缓冲目标，不等于 Windows 到音响的端到端延迟。真实延迟还包括 Windows 音频引擎、发送/接收队列、局域网及音频设备。

保守配置为路由 50 ms、播放器 30 ms、首播接收缓冲 20 ms。有线局域网可从 `30 / 15 / 15` 组合开始测量；出现欠载时应增大对应缓冲。数值更小不保证实际延迟更低。空闲恢复还包括路由建立时间，不能用稳态延迟代表首次出声。

接收端保留采样期限并限制每次追赶的工作量，防止短调度停顿持续累积为播放延迟。内部心跳使用同一主机的单调时钟，系统校时不会被误判为接收器失联。音频仍为 48 kHz / PCM16，不通过升采样率或标称位深声称提高源音质。

软件验证在独立容器中发送 VBAN PCM，并从 PulseAudio 输出监视器录制，检查混音、切换、独立音量、静音释放和恢复。Windows 驱动与实际设备仍需按上述配置完成现场验收。复现命令见[开发文档](development.md)。
