# LAN Audio Bridge

基于 Docker 的局域网音频接收器，支持 AirPlay、DLNA、Spotify Connect 和实验性小米妙播。

## 功能

| 协议 | 接收组件 |
| --- | --- |
| AirPlay | Shairport Sync + NQPTP |
| DLNA / UPnP AV | gmrender-resurrect |
| Spotify Connect | librespot，需要 Premium 账号 |
| 小米妙播（实验性） | MiPlay 接收器，基于 CastFabric 协议模块 |

多个接收器共用一个音频输出，新音源接管时会断开旧会话。MiPlay、专有投放功能及具体客户端的兼容范围见[协议说明](docs/miplay.md)和[部署文档](docs/deployment.md)。

## 部署

需要 Linux amd64、Docker Compose、可用的 ALSA 播放设备，以及可传递局域网多播的网络。

```sh
git clone https://github.com/zxsama/lan-audio-bridge.git
cd lan-audio-bridge
docker build -t lan-audio-bridge:0.2.1 .
cp .env.example .env
```

在 `.env` 中设置已创建的数据目录和声卡名称，以下值需替换为实际配置：

```dotenv
DATA_DIR=/mnt/pool/apps/lan-audio-bridge/data
AUDIO_DEVICE=plughw:CARD=YourCard,DEV=0
```

宿主未运行 Avahi 时：

```sh
docker compose up -d
```

宿主已运行 Avahi 时，使用[代理模式](docs/host-avahi.md)：

```sh
docker compose -f compose.yaml -f compose.host-avahi.yaml up -d
```

项目提供源码构建，未发布公共镜像。TrueNAS Apps 的 YAML 部署及完整配置见[部署文档](docs/deployment.md)。

## 文档

- [配置与运行约定](docs/runtime.md)
- [MiPlay 与播放缓冲](docs/miplay.md)
- [运维与验收](docs/operations.md)
- [开发与测试](docs/development.md)
- [上游组件与构建来源](docs/UPSTREAM.md)

## 许可证

本项目自有代码、脚本和文档采用 [MIT 许可证](LICENSE)。第三方代码与镜像依赖保留各自许可证，详见[第三方声明](THIRD_PARTY_NOTICES.md)。
