# Docker 部署

适用于 Linux amd64、Docker Engine 和 Docker Compose。

## 部署要求

适用于基于 Docker Compose 的 TrueNAS SCALE Apps。旧 Kubernetes 版 SCALE 不适用。TrueNAS 官方提供“Install via YAML”入口，但只做基础语法检查，参数仍需自行核对。[官方说明](https://apps.truenas.com/managing-apps/installing-custom-apps/)

在实际 NAS 主机执行 `sh scripts/probe-host.sh`。脚本只列出 USB、ALSA、网络和相关端口，不安装软件、不播放测试音、不更改系统服务。检查：

1. `/dev/snd` 存在，`aplay -L` 能找到目标声卡。
2. 选择稳定标识，例如 `plughw:CARD=YourUSB,DEV=0`，将 `YourUSB` 换成真实 CARD 名；不使用 `hw:1,0` 等会随重启变化的数字索引。
3. 手机与 NAS 在可相互访问的局域网，网络没有客户端隔离；SSDP/mDNS 多播可达。
4. UDP 319/320 没有其他 PTP 服务占用，NQPTP 使用的 UDP 9000 与接收端控制端口未冲突。UDP 5353/1900 的共享监听需按实际服务调查，不要直接停掉宿主服务。

若宿主 Avahi 已独占 UDP 5353，容器内 Avahi 会出现 `Detected another IPv4 mDNS stack`、`bind() failed: Address already in use`，随后核心进程退出。此时使用[宿主 Avahi 部署说明](host-avahi.md)中的 `compose.host-avahi.yaml`；不要停掉 NAS Avahi，也不要修改宿主全局配置来放开端口。该模式通过独立代理容器复用发现服务，音频容器只接触受限代理 socket。

## 构建与 CLI 部署

以下命令在 Linux 项目目录执行。构建镜像需要下载上游依赖，生成本地镜像 `lan-audio-bridge:0.2.1`。项目未发布公共容器镜像。

```sh
git clone https://github.com/zxsama/lan-audio-bridge.git
cd lan-audio-bridge
docker build --tag lan-audio-bridge:0.2.1 .
cp .env.example .env
```

编辑 `.env`，必填：

```dotenv
DATA_DIR=/mnt/pool/apps/lan-audio-bridge/data
AUDIO_DEVICE=plughw:CARD=YourUSB,DEV=0
```

路径和 `YourUSB` 均为示例，须替换为实际值。部署前创建并确认专用数据目录，用于保存设备身份、Spotify 缓存及授权状态。Compose 使用必填变量与 `create_host_path: false`，路径缺失时拒绝启动。不要将共享资料目录或数据池根目录挂载为 `/data`。

可选参数也有严格校验：`DEVICE_NAME` 最多 50 个 UTF-8 字节，只接受字母、数字、空格及 `._-()`；`NETWORK_INTERFACE` 如果指定，必须在容器内存在且带 IPv4 地址。`SAMPLE_RATE` 只接受 44100、48000、88200、96000、176400、192000，实际还需声卡支持；`OUTPUT_VOLUME` 为 0–100。四个 `ENABLE_*` 可分别设为 `false`，关闭对应接收器。

```sh
docker compose config --quiet
docker compose up -d
sh scripts/status.sh
docker compose logs --tail=100 audio
```

上述命令使用默认 `AVAHI_MODE=internal`，由音频容器启动自己的 D-Bus 和 Avahi。宿主已运行 Avahi 时，按[外部发现模式](host-avahi.md)改用 `docker compose -f compose.yaml -f compose.host-avahi.yaml ...`；仅设置环境变量不足以建立代理挂载。

基础生产配置只有一个服务，使用 host network、`/dev/snd` 映射和指定 `/data`；外部发现模式另加隔离的 `discovery-proxy` 服务。不需要 privileged、Docker socket 或宿主根目录挂载。音频容器以 root 初始化内部服务，删除默认能力后仅保留文件权限、切换服务用户、低端口绑定及终止已降权子进程所需能力；未申请宿主实时调度或网络管理权限。固定大小的 `/run`、`/tmp` 临时文件系统与日志轮转限制临时数据增长，`/data` 使用量仍需由 NAS 监控。

## TrueNAS 自定义 YAML 部署

仓库发布源码与部署文件，不包含预构建镜像或本地 `dist/` 归档。请先按上节构建镜像，再部署或导出。

先确保 NAS 本地 Docker 中已有镜像。如果在另一台 Linux amd64 机器构建，可执行 `docker save -o lan-audio-bridge-0.2.1.tar lan-audio-bridge:0.2.1`，自行传输到 NAS，再执行 `docker load -i lan-audio-bridge-0.2.1.tar`。项目脚本不会自动远程操作 NAS。

填写 `.env` 后在 NAS 项目目录运行：

```sh
docker compose config > compose.rendered.yaml
```

若复用宿主 Avahi，必须渲染组合后的配置，再粘贴到 GUI：

```sh
docker compose -f compose.yaml -f compose.host-avahi.yaml config > compose.rendered.yaml
```

核对渲染后的声卡、主机目录和服务名，再把该文件内容粘贴到 Apps → Discover → Install via YAML。GUI 不一定读取项目旁的 `.env`，因此粘贴已展开变量的 YAML。渲染文件可能带有本机路径，应留在本机。CLI 与 TrueNAS UI 选择一个作为同一实例的管理入口，不要重复启动两份争用音频设备。UI 管理的实例使用 UI 停止/启动和查看日志；CLI 命令示例仅管理 CLI 创建的实例。

## 客户端兼容性

| 项目 | 实现与验收边界 |
| --- | --- |
| AirPlay 2 | Shairport Sync + NQPTP；需局域网 mDNS 与 UDP 319/320 可用，本包 NQPTP 1.2.9 还绑定 UDP 9000。手机真实发现、播放与切换仍须实机验收。[上游说明](https://github.com/mikebrady/shairport-sync) |
| DLNA | gmrender-resurrect 通用 UPnP AV renderer，支持链路以具体媒体 URL、格式和控制端为准。[上游项目](https://github.com/hzeller/gmrender-resurrect) |
| QQ 音乐 / QPlay | 通用 DLNA 支持不等同于 QPlay 专有协议支持。本项目未实现 QPlay 专有发现或认证；客户端和资源兼容性须按实际版本验证。 |
| Spotify Connect | librespot；需要 Spotify Premium，初始发现、授权及云端播放需要网络。[上游要求](https://github.com/librespot-org/librespot) |
| 小米妙播 | 实验性 MiPlay 接收：mDNS/TCP 控制、WFD/RTSP、AAC 解码到 PCM，再写入隔离总线。不含 CoAP/旧版 5355 发现；不能保证所有 HyperOS 版本。见[范围与配置](miplay.md)。 |
| 音量 | `OUTPUT_VOLUME` 是共同输出的百分比；客户端音量还可能在各协议内衰减。不承诺各客户端音量显示同步。 |
| 歌曲信息 | 支持范围取决于接收协议；项目不提供统一封面或歌词界面。 |
| Apple Music / 多房间 | Apple Music 和受保护内容不在已验证范围内；项目不提供跨设备同步。 |
