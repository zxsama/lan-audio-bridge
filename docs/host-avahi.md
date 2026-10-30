# 复用 NAS 的 Avahi 发现服务

自 0.1.1 起提供 `AVAHI_MODE=external`，用于已经运行 Avahi 的 Linux NAS。音频容器保持 host network，由独立 `discovery-proxy` 容器向宿主 Avahi 申请 AirPlay/Spotify/MiPlay 服务公告；不停止 NAS 服务，不修改宿主 Avahi 或 D-Bus 全局配置。默认 `AVAHI_MODE=internal` 仍在音频容器内运行自己的 D-Bus 和 Avahi。

## 5353 冲突的原因

host-network 容器与 NAS 共用网络命名空间。当宿主 Avahi 独占 UDP 5353 时，第二个 Avahi 即使尝试共享绑定也会失败，日志可能依次出现 `Detected another IPv4 mDNS stack`、`bind() failed: Address already in use`、`No suitable network protocol available`，随后监督器因核心服务退出而重启容器。[Avahi 0.8 的绑定实现](https://github.com/avahi/avahi/blob/v0.8/avahi-core/socket.c)

Avahi 上游 `disallow-other-stacks` 默认是 `no`，但 TrueNAS 25.10.0 的官方模板明确设为 `yes`。给容器再加一次 `no` 无法解除宿主的独占绑定。不同 TrueNAS 版本应核对实际配置，不能仅凭报错断定占用者是谁。[上游配置说明](https://github.com/avahi/avahi/blob/master/man/avahi-daemon.conf.5.xml.in)、[TrueNAS 25.10.0 模板](https://github.com/truenas/middleware/blob/release/25.10.0/src/middlewared/middlewared/etc_files/local/avahi/avahi-daemon.conf.mako)

部署前在 NAS 只读检查：

```sh
ss -ulpn 'sport = :5353'
systemctl is-active avahi-daemon
test -S /run/dbus/system_bus_socket && echo DBUS_SOCKET_OK
```

确认实际占用服务是宿主 Avahi，且 D-Bus socket 存在。socket 存在本身不证明 Avahi API 可调用，启动后的代理健康检查还会调用 `GetVersionString`。若主机没有可用 Avahi，先调查其正常配置，不用关闭其他 NAS 服务来让本项目抢占端口。

## 安装与 TrueNAS YAML

按 [README](../README.md) 构建本地镜像 `lan-audio-bridge:0.2.0`，创建专用数据集并填写 `.env` 的 `DATA_DIR`、`AUDIO_DEVICE`。此模式仍需要真实声卡映射和既有音频配置，仅改变发现服务的接入方式。

在 Linux 项目目录执行：

```sh
docker compose -f compose.yaml -f compose.host-avahi.yaml config --quiet
docker compose -f compose.yaml -f compose.host-avahi.yaml up -d
docker compose -f compose.yaml -f compose.host-avahi.yaml ps
docker compose -f compose.yaml -f compose.host-avahi.yaml logs --tail=100 audio discovery-proxy
```

`compose.host-avahi.yaml` 是明确的生产 override，必须与 `compose.yaml` 组合；不要单独使用，也不要与 `compose.test.yaml` 或 `compose.local.yaml` 合并。后两者是独立 bridge 网络配置。仅设置 `AVAHI_MODE=external` 不会自动创建代理、依赖或 socket 挂载。

使用 TrueNAS Apps → Discover → Install via YAML 时，先生成完整配置：

```sh
docker compose -f compose.yaml -f compose.host-avahi.yaml config > compose.rendered.yaml
```

核对两个服务都使用当前本地镜像、音频服务保持 `network_mode: host`、声卡和数据目录正确，再将渲染结果粘贴到 GUI。GUI 不一定读取项目旁的 `.env`。同一实例只选 CLI 或 GUI 管理，避免启动两份争用声卡；渲染文件含本机路径，留在本机。

## socket 与权限边界

| 组件 | 可访问内容 | 行为 |
| --- | --- | --- |
| `audio` | `/data`、声卡、`avahi-bus` 卷在 `/run/dbus:ro` | 不启动自己的 D-Bus/Avahi；接收器使用 `/run/dbus/system_bus_socket` 的受限代理 |
| `discovery-proxy` | 宿主 `/run/dbus` 在 `/run/host-dbus:ro`、代理输出卷在 `/proxy` | `python3 /app/avahi_proxy.py` 启动过滤代理；`network_mode: none`、`cap_drop: ALL`、只读根文件系统 |

音频容器不挂载原始宿主 bus。将原始 socket 以 `:ro` 挂载给音频容器仍允许其直接连接总线；把代理与音频进程放进同一个可访问原始 socket 的容器也不能建立这条限制。[Debian 对代理隔离的说明](https://packages.debian.org/trixie/xdg-dbus-proxy)

代理按方法放行 Avahi Server 的所需只读查询及 `EntryGroupNew`、`EntryGroup.*`、只读 introspection/properties 与 `Peer.Ping`，并允许 Server/EntryGroup `StateChanged` 信号。它不使用宽泛的 `--talk`/`--own`，不允许 `SetHostName` 或调用其他宿主服务。标准 D-Bus 连接与名称跟踪仍由过滤代理处理；这不是完全无方法调用的只读连接，接收器需要创建、更新和撤销自己的公告。

Avahi 的动态对象位于 `/ClientN/EntryGroupN` 等路径，规则不固定某个实例编号。代理保留每个客户端的独立上游连接和响应，支持用于注册状态通知的定向 signal；宿主仍保有自身 D-Bus 授权策略。[代理协议说明](https://github.com/flatpak/xdg-dbus-proxy/blob/main/xdg-dbus-proxy.xml)、[Avahi 动态对象](https://github.com/avahi/avahi/blob/v0.8/avahi-daemon/dbus-protocol.c)、[EntryGroup 信号](https://github.com/avahi/avahi/blob/v0.8/avahi-daemon/dbus-entry-group.c)

镜像要求 Debian `xdg-dbus-proxy >= 0.1.6-1+deb13u3`，包含发行版回移修复；不能只看上游 `0.1.6` 字样判断包是否修复。来源、许可证与官方版本依据见 [UPSTREAM.md](UPSTREAM.md)。

## 网络与恢复范围

该部署只适用于音频服务与提供 Avahi 的宿主共用 host network。公告中的宿主地址必须能访问对应接收端口；普通 bridge 容器不能直接套用这套宿主公告方式。它也不解决 NQPTP 的 UDP 319/320/9000、SSDP 或其他接收端口冲突。

宿主 Avahi 的接口允许/拒绝列表、发布策略和局域网多播可达性继续生效。`NETWORK_INTERFACE` 只影响本项目接收器，不能覆盖宿主策略；代理健康不等于手机可发现。服务公告使用宿主的网络身份，接收器可见名称仍由项目配置和协议实现决定。

启动、健康检查和监督器周期探测均通过代理调用 Avahi `GetVersionString`。代理或宿主 Avahi 失联时，监督器退出音频进程，由 Compose 的重启策略恢复；健康状态变为 unhealthy 本身不会让 Docker 重启。代理重启会断开现有连接并使旧公告失效，重新注册存在短暂中断，不能承诺播放无缝保持。

完成软件与实机验收时分别记录：

- 独立隔离测试 `python3 -B tests/host_avahi.py --image lan-audio-bridge:0.2.0` 的实际输出，确认代理访问限制、动态公告及故障恢复；该测试不访问真实宿主总线或声卡，运行说明见[开发文档](development.md)。
- NAS 上两个容器健康、`audio` 无内部 D-Bus/Avahi，客户端能发现并连接 AirPlay/Spotify；启用 MiPlay 时按其兼容范围单独验收；DLNA 仍按原路径验收。
- 重建音频容器、重启代理后，重新注册、手机重新发现及实际播放均恢复。CLI 部署可在允许中断播放时用组合命令 `restart discovery-proxy`；GUI 部署使用对应管理入口。
- 宿主 Avahi 重启后重新公告与播放恢复，只在允许维护宿主发现服务的窗口验收；不要为本项目调试擅自停启它。隔离测试通过不能代替真实 NAS 的此项记录。
- 真实 AirPlay 2 手机传音、Spotify 账号播放、跨协议切换及 USB 光纤出声，按[运维文档](operations.md)单独验收。

本文提供配置与验收方法，不宣称上述真实 NAS 场景已通过。更新镜像、代理规则或 TrueNAS 后，应重跑受影响项目。排查时保留必要日志并脱敏，不清空 `/data`、不扩大宿主 D-Bus 权限，也不修改 NAS 全局 Avahi 配置。
