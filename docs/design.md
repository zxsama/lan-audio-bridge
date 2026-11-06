# 方案选择

目标是让手机选择局域网音频接收器，并将音频统一输出到配置的 ALSA 播放设备，不增加音乐库管理界面。本文记录 2026-10-28 的三协议初始设计；0.2.0 新增的实验性 MiPlay 见 [MiPlay 文档](miplay.md)，0.3.0 的电脑混音输入见[电脑音频文档](desktop-audio.md)，当前运行约定见 [runtime.md](runtime.md)。以下分析区分上游能力说明与已完成的软件验证。

| 现成项目 | 主要数据路径 | 与本需求的关系 |
| --- | --- | --- |
| [Shairport Sync](https://github.com/mikebrady/shairport-sync) | 苹果发送端 → AirPlay 接收 → 本地音频后端 | 可直接复用 AirPlay 接收实现；AirPlay 2 需要 [NQPTP](https://github.com/mikebrady/nqptp)。单独部署不能协调另外两种来源。 |
| [gmrender-resurrect](https://github.com/hzeller/gmrender-resurrect) | UPnP 控制端给 URL → renderer 拉取媒体 → GStreamer | 适合作为 DLNA 接收实现。不同控制端是否提供可访问 URL、鉴权和编码需实际验证；无 QPlay 专有兼容保证。 |
| [librespot](https://github.com/librespot-org/librespot) | Spotify Connect 选择目标 → 接收端连接 Spotify → 本地音频 | 复用 Connect 实现，需要 Premium；服务和客户端版本变化可能影响兼容性。 |
| [iotsound（原 balenaSound 链接重定向目标）](https://github.com/iotsound/iotsound) | 面向树莓派的 AirPlay / Spotify / 蓝牙播放器 | 已有多接收源集成，偏设备系统和单/多房间体验；迁移其部署体系到 TrueNAS、加入目标 DLNA 与严格的独占规则仍要额外适配。 |
| [OwnTone](https://github.com/owntone/owntone-server) | 音乐库/服务 → 本地或 AirPlay/Chromecast 播放设备 | 更适合服务器管理音乐库并向其他设备发送；其 AirPlay 输出能力不能直接当作手机 AirPlay 接收入口。 |
| [LMS-uPnP](https://github.com/philippe44/LMS-uPnP) | Logitech Media Server → UPnP 播放器 | 解决 LMS 到已有播放器的桥接，和“让 NAS 自己成为三协议接收器”方向不同。 |

因此复用三个成熟接收程序，只编写部署和输出协调层。统一使用 PulseAudio 是为了让一个进程打开实际 ALSA 设备，避免三个后端分别抢占声卡或在 `dmix` 中混合。每个接收器只能输出到自己的 null sink；默认 sink 是 discard；硬件 output 与源之间只有协调器创建的一条 loopback。

新 active 流可以接管；先卸载旧路由，再创建新路由。路由变化失败则保持无输出。接管后重启旧接收器，使旧客户端会话断开，并抑制仍存活的旧流 ID，直到该流消失。旧客户端若主动创建新会话重新播放，则属于新请求，仍可能再次接管。本版不在协议层向所有手机伪装“暂停”状态，不保证它们 UI 一致。连续 active 的静音流仍被视为播放，这是基于流状态而非音量阈值的明确选择。

同一轮轮询中同时出现多个新音源无法还原精确先后时，采用固定次序 AirPlay、DLNA、Spotify；正常情况下由新开始播放的来源接管。仅检测实际 active 流，发现广播、TCP 连接或标题 metadata 不授予输出权限。播放停止后不自动回退到先前来源，以免旧歌曲重新出声。

生产 host network 用于局域网发现，避免把复杂的发现/媒体端口映射当作已解决。一个容器可以减少跨容器音频认证和 socket 权限配置，但仍有容器内多进程监督成本。镜像中各上游版本与构建信息由 [UPSTREAM.md](UPSTREAM.md) 维护；版本固定不等于上游服务兼容性永久稳定。

本地数字采样只能验证进入 output 的音频是否单一来源；不能验证物理音频输出、客户端发现和应用会员内容。数据目录、ALSA 设备标识和局域网接口需按部署环境配置。
