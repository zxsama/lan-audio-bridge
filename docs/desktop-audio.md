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

双击仓库根目录的 [`Setup-Windows-Audio.cmd`](../Setup-Windows-Audio.cmd)，输入 NAS 的 IPv4 地址。脚本配置低延迟驱动和原生发送端，在 Windows 声音设置中提供“NAS 音频”输出，并登录自启。完整行为、恢复与实测见 [Windows 一键配置](windows-setup.md)。

也可使用任何符合上述格式的 VBAN 发送端（例如 Voicemeeter：Virtual Input → BUS B → VBAN Outgoing Stream，填 NAS 地址、端口 `6980`、流名 `Windows`、`48000 Hz / 2 channels / PCM 16 bits`）。经过 Voicemeeter 时 Windows 侧实测至少约 45 ms。同一源地址和流名同时只能有一路发送。

## 混音与空闲行为

电脑和手机各保留一条输出路由。任一路暂停、断开或重连，不会停止另一条路由；手机切换协议只替换手机路由。MiPlay 的手机音量仍只控制 MiPlay 输入。

单路播放保持原有增益；两路同时播放时，各路自动预留约 6.02 dB 的混音余量，降低满幅叠加造成的削顶。公共 `OUTPUT_VOLUME` 仍是总输出音量。电脑音量可由 Windows、Voicemeeter 或 `DESKTOP_VOLUME` 调整。

默认 Python 后端在首次有效声音到达时请求桌面路由，并等待路由就绪后提交音频，以保留短提示音；原生后端复用预先建立的暂停流。连续全零样本或断流达到空闲等待时间后，等待下游缓冲排空，再释放播放器或暂停原生流；低音量但非零的声音不会因门限检测被裁掉。双方都停止后才挂起公共输出，任一方恢复即唤醒。持续非零噪声会保持电脑输入活动。

## 延迟与验证

电脑路由使用独立缓冲，不改变 `DLNA_BUFFER_MS` 和手机 `OUTPUT_BUFFER_MS`。配置值仅是软件缓冲目标，不等于 Windows 到音响的端到端延迟。真实延迟还包括 Windows 音频引擎、发送/接收队列、局域网及音频设备。

保守配置为路由 50 ms、播放器 30 ms、首播接收缓冲 20 ms。有线局域网可从 `30 / 15 / 15` 组合开始测量；出现欠载时应增大对应缓冲。数值更小不保证实际延迟更低。空闲恢复还包括路由建立时间，不能用稳态延迟代表首次出声。

接收端保留采样期限并限制每次追赶的工作量，防止短调度停顿持续累积为播放延迟。内部心跳使用同一主机的单调时钟，系统校时不会被误判为接收器失联。音频仍为 48 kHz / PCM16，不通过升采样率或标称位深声称提高源音质。

软件验证在独立容器中发送 VBAN PCM，并从 PulseAudio 输出监视器录制，检查混音、切换、独立音量、静音释放和恢复。Windows 驱动与实际设备仍需按上述配置完成现场验收。复现命令见[开发文档](development.md)。

## 原生低延迟后端

`DESKTOP_BACKEND=native` 启用原生 VBAN 接收器，直接写入公共 PulseAudio 输出。该路径移除电脑输入的 `pacat`、虚拟总线和 loopback，保留手机仲裁、独立音量、混音余量与空闲挂起。默认后端仍为 `python`。

```dotenv
DESKTOP_BACKEND=native
DESKTOP_NATIVE_LATENCY_MS=16
DESKTOP_NATIVE_JITTER_MS=8
```

原生模式不使用 `DESKTOP_BUFFER_MS`、`DESKTOP_PLAYER_MS` 和 `DESKTOP_JITTER_MS`。`DESKTOP_NATIVE_LATENCY_MS` 请求 PulseAudio 的总体播放延迟，范围 4–30 ms；`DESKTOP_NATIVE_JITTER_MS` 控制初始积累和有限重排等待，范围 1–20 ms。两者都不是端到端延迟承诺，必须检查服务器实际协商结果。

原生模式下 PulseAudio 使用 `speex-float-5` 重采样，其滤波参数较 Q1 保留更宽的通带，参见 [SpeexDSP 实现](https://github.com/xiph/speexdsp/blob/master/libspeexdsp/resample.c)。传输格式仍为 48 kHz / PCM16；该设置不增加源音频的有效位深，也不代表免除实际音质与延迟验收。

原生后端目前为实验功能。16/8 ms 已通过本机隔离环境中 ±200 ppm 发送时钟偏差的两组 120 秒严格测试；更小的 8/4 和 12/6 ms 配置出现过欠载，不能作为稳定配置推荐。设备要求更大缓冲时，控制目标按实际协商结果提高，状态会报告真实目标。Windows 发送、实际音频设备、长期时钟偏差及目标主机负载仍需单独验收。测量结果和边界见[延迟验证](latency.md)，控制协议见[原生接收器](../native/README.md)。
