# LAN Audio Bridge 0.2.0

在 TrueNAS SCALE（Linux amd64）上部署 AirPlay、通用 DLNA renderer、Spotify Connect 和实验性小米妙播（MiPlay）接收器，共用一只 USB 声卡输出。每个协议使用独立接收进程，PulseAudio 独占指定 ALSA 设备；协调器只允许一个音源通往硬件。新开始播放的音源接管输出，旧接收进程会断开并重启，因此旧手机不保证显示“暂停”。这不是无缝切歌或多房间同步产品。

0.2.0 新增妙播接收通道，并将 DLNA 播放端 PCM 缓冲默认设为 1000ms，以增加短时网络停顿的余量；代价是起播/恢复可能稍慢。妙播复用已有 Avahi，不另占 UDP 5353。实现范围见[妙播与播放缓冲](docs/miplay.md)，测试结果见[0.2.0 软件验证](docs/verification-0.2.0.md)。真实手机/HyperOS 兼容性仍须实测；本轮没有部署或操作 TrueNAS。

此前版本已通过容器内音频隔离、真实 DLNA 和 RAOP/AirPlay 1 软件验证，详见保留原版本信息的[验证记录](docs/local-validation-2026-10-29.md)。0.1.1 的宿主 Avahi 复用、代理隔离和故障恢复已通过隔离 Docker 测试，见[0.1.1 验证记录](docs/verification-0.1.1.md)。AirPlay 2 手机传音、Spotify 账号播放、QQ 音乐/网易云兼容性及 USB 光纤实际出声仍待实机验收。

```text
iPhone / DLNA 控制端 / Spotify Premium / 小米妙播
              ↓ 局域网协议
Shairport Sync / gmrender-resurrect / librespot / MiPlay
              ↓ 四个隔离音频总线
       单一活动音源协调器
              ↓ 唯一音频路由
PulseAudio → USB UAC 声卡 → 光纤 PCM → 音箱光纤输入
```

USB 转光纤设备必须被 Linux 识别成 USB Audio Class（UAC）声卡，并实际支持目标采样率的双声道 PCM 输出。普通 USB 转接线、只供电 USB 口和只支持数字输入的设备不满足条件。先确认 USB 声卡，再选择音箱的光纤输入；本项目不依赖音箱内置网络模块，也不修改音箱固件。

目标适配器是用户指定的[京像商品](https://item.jd.com/10231416559827.html)，选项“灰色 USB 转光纤母-24B”。商品页需要登录，规格未从页面核验。2026-10-30 在用户 NAS 上实测 USB AUDIO DAC 已被 Linux 识别，稳定 CARD 名为 `DAC`；0.1.2 的 Pulse 成功打开该设备，ALSA 当前参数为 S24_3LE、双声道、48000 Hz，见[设备验证记录](docs/verification-0.1.2.md)。光纤音箱实际出声及端到端 bit-perfect 尚未验收。其他设备部署前仍应查看 `/proc/asound/cardN/stream0` 的 Playback、Format、Channels、Rates；`probe-host.sh` 会只读打印这些能力信息。

## 能力与边界

| 项目 | 实现与验收边界 |
| --- | --- |
| AirPlay 2 | Shairport Sync + NQPTP；需局域网 mDNS 与 UDP 319/320 可用，本包 NQPTP 1.2.9 还绑定 UDP 9000。手机真实发现、播放与切换仍须实机验收。[上游说明](https://github.com/mikebrady/shairport-sync) |
| DLNA | gmrender-resurrect 通用 UPnP AV renderer，支持链路以具体媒体 URL、格式和控制端为准。[上游项目](https://github.com/hzeller/gmrender-resurrect) |
| QQ 音乐 / QPlay | 先验证应用是否愿意把媒体交给通用 renderer；通用 DLNA 通过不等于 QPlay 专有发现、认证或会员资源可用。本项目未实现 QPlay 专有协议，需用户版本真机验证。 |
| Spotify Connect | librespot；需要 Spotify Premium，初始发现、授权及云端播放需要网络。[上游要求](https://github.com/librespot-org/librespot) |
| 小米妙播 | 实验性 MiPlay 接收：mDNS/TCP 控制、WFD/RTSP、AAC 解码到 PCM，再写入隔离总线。不含 CoAP/旧版 5355 发现；不能保证所有 HyperOS 版本。见[范围与配置](docs/miplay.md)。 |
| 音量 | `OUTPUT_VOLUME` 是共同输出的百分比；客户端音量还可能在各协议内衰减。不承诺各客户端音量显示同步。 |
| 歌曲信息 | metadata 是标题、封面等附加信息，不是把音频送到音箱的输出协议；本版不提供统一封面/歌词界面。 |
| Apple Music / 多房间 | 不纳入本次验收范围；不承诺相关平台、受保护内容或跨设备同步。 |

## 部署前只读检查

适用于基于 Docker Compose 的 TrueNAS SCALE Apps。旧 Kubernetes 版 SCALE 不适用。TrueNAS 官方提供“Install via YAML”入口，但只做基础语法检查，参数仍需自行核对。[官方说明](https://apps.truenas.com/managing-apps/installing-custom-apps/)

在实际 NAS 主机执行 `sh scripts/probe-host.sh`。脚本只列出 USB、ALSA、网络和相关端口，不安装软件、不播放测试音、不更改系统服务。检查：

1. `/dev/snd` 存在，`aplay -L` 能找到目标声卡。
2. 选择稳定标识，例如 `plughw:CARD=YourUSB,DEV=0`，将 `YourUSB` 换成真实 CARD 名；不使用 `hw:1,0` 等会随重启变化的数字索引。
3. 手机与 NAS 在可相互访问的局域网，网络没有客户端隔离；SSDP/mDNS 多播可达。
4. UDP 319/320 没有其他 PTP 服务占用，NQPTP 使用的 UDP 9000 与接收端控制端口未冲突。UDP 5353/1900 的共享监听需按实际服务调查，不要直接停掉宿主服务。

若宿主 Avahi 已独占 UDP 5353，容器内 Avahi 会出现 `Detected another IPv4 mDNS stack`、`bind() failed: Address already in use`，随后核心进程退出。此时使用[宿主 Avahi 部署说明](docs/host-avahi.md)中的 `compose.host-avahi.yaml`；不要停掉 NAS Avahi，也不要修改宿主全局配置来放开端口。该模式通过独立代理容器复用发现服务，音频容器只接触受限代理 socket。

## 构建与 CLI 部署

以下命令在 Linux 项目目录执行。构建镜像需要下载上游依赖，镜像名为本地 `lan-audio-bridge:0.2.0`，没有假定存在的公共镜像仓库。

```sh
git clone https://github.com/zxsama/lan-audio-bridge.git
cd lan-audio-bridge
docker build --tag lan-audio-bridge:0.2.0 .
cp .env.example .env
```

编辑 `.env`，必填：

```dotenv
DATA_DIR=/mnt/你的池/专用数据集/lan-audio-bridge
AUDIO_DEVICE=plughw:CARD=你的真实CARD名,DEV=0
```

上面是占位示例，不是可直接使用的路径。先在 TrueNAS 中创建并确认专用数据目录；其内容会保存 DLNA UUID、Spotify 缓存或授权状态，按敏感数据管理。Compose 使用必填变量与 `create_host_path: false`，路径缺失时拒绝启动，不自动在任意位置创建目录。不要将共享资料目录或数据池根目录挂到 `/data`。

可选参数也有严格校验：`DEVICE_NAME` 最多 50 个 UTF-8 字节，只接受字母、数字、空格及 `._-()`；`NETWORK_INTERFACE` 如果指定，必须在容器内存在且带 IPv4 地址。`SAMPLE_RATE` 只接受 44100、48000、88200、96000、176400、192000，实际还需声卡支持；`OUTPUT_VOLUME` 为 0–100。四个 `ENABLE_*` 可分别设为 `false`，关闭对应接收器。

```sh
docker compose config --quiet
docker compose up -d
sh scripts/status.sh
docker compose logs --tail=100 audio
```

上述命令使用默认 `AVAHI_MODE=internal`，由音频容器启动自己的 D-Bus 和 Avahi。宿主已运行 Avahi 时，按[外部发现模式](docs/host-avahi.md)改用 `docker compose -f compose.yaml -f compose.host-avahi.yaml ...`；仅设置环境变量不足以建立代理挂载。

基础生产配置只有一个服务，使用 host network、`/dev/snd` 映射和指定 `/data`；外部发现模式另加隔离的 `discovery-proxy` 服务。不需要 privileged、Docker socket 或宿主根目录挂载。音频容器以 root 初始化内部服务，删除默认能力后仅保留文件权限、切换服务用户、低端口绑定及终止已降权子进程所需能力；未申请宿主实时调度或网络管理权限。固定大小的 `/run`、`/tmp` 临时文件系统与日志轮转限制临时数据增长，`/data` 使用量仍需由 NAS 监控。

## TrueNAS 自定义 YAML 部署

仓库发布源码与部署文件，不包含预构建镜像或本地 `dist/` 归档。请先按上节构建镜像，再部署或导出。

先确保 NAS 本地 Docker 中已有镜像。如果在另一台 Linux amd64 机器构建，可执行 `docker save -o lan-audio-bridge-0.2.0.tar lan-audio-bridge:0.2.0`，自行传输到 NAS，再执行 `docker load -i lan-audio-bridge-0.2.0.tar`。项目脚本不会自动远程操作 NAS。

填写 `.env` 后在 NAS 项目目录运行：

```sh
docker compose config > compose.rendered.yaml
```

若复用宿主 Avahi，必须渲染组合后的配置，再粘贴到 GUI：

```sh
docker compose -f compose.yaml -f compose.host-avahi.yaml config > compose.rendered.yaml
```

核对渲染后的声卡、主机目录和服务名，再把该文件内容粘贴到 Apps → Discover → Install via YAML。GUI 不一定读取项目旁的 `.env`，因此粘贴已展开变量的 YAML。渲染文件可能带有本机路径，应留在本机。CLI 与 TrueNAS UI 选择一个作为同一实例的管理入口，不要重复启动两份争用音频设备。UI 管理的实例使用 UI 停止/启动和查看日志；CLI 命令示例仅管理 CLI 创建的实例。

## 日常操作与恢复

0.1.2 将 PulseAudio 改为专用 `pulse` 用户运行，并由 `dbus-run-session` 提供私有会话总线。其 HOME 和运行目录归该用户所有；Unix 音频 socket 延续容器内匿名访问，显式禁用不使用的 cookie 认证。由此解决系统模式、HOME、缺失 cookie 及误连发现代理的 D-Bus 警告，同时保留音源切换必需的动态模块加载。无需设置 `--disallow-module-loading`，也无需放宽宿主 D-Bus 权限。硬件模式按实际 `/dev/snd` 字符设备的组号授予 Pulse 访问权，见 [0.1.2 验证记录](docs/verification-0.1.2.md)。

`sh scripts/status.sh` 只读显示容器状态、协调器状态和 Pulse 模块；`owner` 是 `airplay`、`dlna`、`spotify`、`miplay` 或 `null`。停止当前客户端播放/断开连接后，旧音源不会自动恢复，必须重新开始播放才能争取输出。源暂停保留已打开的流不等于播放，协调器根据 Pulse 流的 active/corked 状态判断。

本版没有独立的远程 release API。要明确释放全部会话并恢复空闲：先停掉客户端播放，然后在 CLI 部署中运行 `docker compose restart audio`；它会中断所有会话并短暂重新广播服务。如果客户端仍在主动重连，重启后它可能再次成为 owner。

接收进程异常会按有限退避重启；Pulse、内部模式的 D-Bus/Avahi 或 NQPTP 等核心进程退出时容器退出，生产 Compose 重启整个服务。外部模式不启动自己的 D-Bus/Avahi，健康检查与监督器周期探测代理后的 Avahi；失联时监督器退出，由 Docker 重启音频服务。健康检查标记 unhealthy 本身不会触发 Docker 重启；故障诊断见 [运维与验收](docs/operations.md)。设备移除或重插、NAS 重启、真实声卡格式兼容性需要硬件验收，不应由 null 输出测试推断成功。

为避免接收器把账号标识或带签名的媒体 URL 打入日志，其原始 stdout/stderr 被抑制；运行时记录启动、退出码、退避与 owner 变化。核心 Pulse/D-Bus/Avahi/NQPTP 日志仍输出，因此原始协议错误的诊断信息有限。`/data/dbus-machine-id` 保存容器的稳定机器标识，Spotify 只保留登录缓存、禁用音频文件缓存。

## 无硬件测试

Windows 本机需要保留运行的软件演示，可使用 [本机部署说明](docs/local-deployment.md) 中的 `scripts/local.ps1 Start / Status / Stop`。它使用独立 `compose.local.yaml` 和 null 输出，与以下测试实例分开；不代表手机局域网发现或 USB 光纤硬件已验证。

测试配置是独立文件，不能和生产文件合并。它使用 bridge 网络、独立 Docker volume、null 输出，不映射 `/dev/snd`，也不发布端口；不会播放到真实声卡。

```sh
docker compose -f compose.test.yaml up -d --wait --wait-timeout 120
python3 tests/integration.py
python3 tests/pulse_startup.py
python3 tests/recovery.py
python3 tests/discovery.py
docker compose -f compose.test.yaml down
```

集成测试使用 Python 标准库和本地 Docker CLI：向真实 Pulse 四个输入总线注入不同频率音频，在 `output.monitor` 实际录音并检查唯一音源；随后通过真实 DLNA SOAP 测试 HTTP WAV 的播放、暂停、Seek 和停止。`recovery.py` 会主动终止测试容器中的接收器和 Pulse 进程，验证监督重启、核心故障退出、容器重启后的持久身份与空闲状态，以及正常停止；它只应针对独立 null 输出测试实例运行。这些测试证明容器内管线与恢复行为，不证明 iPhone AirPlay 2、Spotify 账号、QQ 音乐 QPlay、NAS 多播或 USB 光纤硬件的可用性。首次保留测试 volume 便于诊断；确认不需要其测试状态后可用 `docker compose -f compose.test.yaml down --volumes` 删除测试卷。

独立发现测试从另一个容器查询 mDNS/SSDP 并检查广告端点。另可在关闭测试实例之前执行 `python3 tests/airplay_sender.py`，验证真实 RAOP/AirPlay 1 音频；它会在临时发送容器中下载固定版本测试依赖，完成后自动清理。该测试不代表 AirPlay 2 传音通过，细节见 [AirPlay 发送测试](docs/airplay-sender-validation.md)。

## 工程与文档

- [开发与测试](docs/development.md)：目录用途、单元测试、软件验证及本地文件管理。
- [方案选择](docs/design.md)与[运行时约定](docs/runtime.md)：接收器选择、配置接口和音源协调规则。
- [运维与真机验收](docs/operations.md)、[Windows 本机部署](docs/local-deployment.md)。
- [复用宿主 Avahi](docs/host-avahi.md)：5353 冲突、独立代理与 TrueNAS 组合 YAML 部署。
- [初次构建验证](docs/verification.md)、[2026-10-29 软件验证](docs/local-validation-2026-10-29.md)、[AirPlay 发送测试](docs/airplay-sender-validation.md)。
- [上游来源与许可证说明](docs/UPSTREAM.md)。本项目自有代码尚未指定许可证；各上游组件保留自己的许可证。
