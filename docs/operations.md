# 运维、验收与恢复

CLI 与 TrueNAS UI 应选择一个作为同一实例的管理入口。以下命令适用于 CLI 创建的实例；UI 管理的实例在 UI 中停止、启动和查看日志，避免重复启动两份服务争用声卡。

## 观察

- `docker compose ps`：容器与健康状态。
- `sh scripts/status.sh`：当前 owner、路由与接收进程状态；检查空闲时无 loopback，播放时只一条通往 output。
- `docker compose logs --tail=100 audio`：最近日志；不要向他人上传 `/data` 缓存、授权信息或完整未经检查的日志。
- `sh scripts/probe-host.sh`：在宿主机重新检查 USB/ALSA、接口和端口，不做任何服务修复。

`status.sh` 只读显示容器状态、协调器状态和 Pulse 模块；`owner` 为 `airplay`、`dlna`、`spotify`、`miplay` 或 `null`。停止当前客户端播放或断开连接后，旧音源不会自动恢复，必须重新开始播放才能争取输出。暂停后保留已打开的流不等于播放，协调器根据 Pulse 流的 active/corked 状态判断。

接收器原始 stdout/stderr 被抑制，避免账号标识或带签名的媒体 URL 进入日志；运行时记录启动、退出码、退避与 owner 变化。核心 Pulse/D-Bus/Avahi/NQPTP 日志仍输出，因此原始协议错误的诊断信息有限。`/data/dbus-machine-id` 保存稳定机器标识；Spotify 保留登录缓存，禁用音频文件缓存。

本包 NQPTP 1.2.9 会绑定 UDP 319、320、9000；三个端口都应纳入冲突检查。发现冲突先确认占用服务的职责，不直接终止宿主服务。

采用宿主 Avahi 模式时，本页所有 `docker compose` 操作均需加 `-f compose.yaml -f compose.host-avahi.yaml`，日志同时检查 `audio` 和 `discovery-proxy`。代理是否健康与手机是否能收到公告是两项检查；完整安装、权限边界和命令见[宿主 Avahi](host-avahi.md)。

`OUTPUT_VOLUME` 默认 100%，首次接线先降低音箱物理音量。只有目标声卡被识别、容器健康且选中正确输入后，再用客户端低音量开始播放。输出统一为双声道 PCM，采样率默认 48 kHz；设备须支持所配置的格式，不保证 bit-perfect 或环绕编码输出。

0.2.2 起，公共输出默认不额外衰减（100%，0 dB）。已有部署若显式配置 `OUTPUT_VOLUME=70`，需修改配置才能采用新默认值。

启动空闲、播放停止或所有输入均暂停时，协调器卸载输出路由并挂起 `output`；新音源开始时自动恢复。可通过 `pactl list sinks` 检查空闲输出为 `SUSPENDED`。软件挂起停止音频数据输出并释放 ALSA 设备；外接硬件是否关闭自身载波或进入待机由硬件决定。

## 真机验收记录

下面均需实际设备与账号，未勾选项不能由单元测试或 null sink 替代。记录宿主系统版本、音频设备型号/CARD、客户端系统/版本、网络接口和测试时间，不记录凭证。

- [ ] 宿主启动后无需改设备索引即可识别配置的 ALSA 播放设备。
- [ ] 目标设备支持所配置的双声道 PCM 格式和采样率（默认 48 kHz）。
- [ ] 低音量验证实际音频输出，左右声道与采样率正常。
- [ ] iPhone 能发现 AirPlay 2 目标，实际连续播放、暂停、恢复和切换曲目。
- [ ] 一个已知兼容的 DLNA 控制端能播放 NAS 可访问的媒体 URL，暂停、Seek、停止。
- [ ] 目标 QQ 音乐版本能发现并播放到通用 renderer；若不支持，记录该客户端版本与通用 renderer 的兼容性限制。
- [ ] Spotify Premium 客户端发现、授权、播放、暂停、恢复，重启后缓存状态正常。
- [ ] AirPlay → DLNA、DLNA → AirPlay、AirPlay → Spotify、Spotify → AirPlay、DLNA → Spotify、Spotify → DLNA 六种切换；仅新来源出声。
- [ ] 被接管的手机不必显示暂停，但没有旧来源悄悄混音或自动恢复；重新主动播放可以争取输出。
- [ ] 新来源停止后保持空闲；迟到的旧来源关闭事件不误停当前来源。
- [ ] 同协议两台客户端的行为分别按 Shairport / gmrender / librespot 实现记录；不推断为跨协议协调器保证。
- [ ] NAS 重启、容器重启和局域网短暂断线后的重新发现与播放。
- [ ] 外部发现模式：音频服务重建及代理重启后重新注册 AirPlay/Spotify，实际客户端可发现和播放；代理不能调用其他宿主服务或 Avahi `SetHostName`。
- [ ] 外部发现模式：在允许维护宿主发现服务的窗口验证宿主 Avahi 重启后重新注册与播放；不要为排查单个应用直接重启 NAS 发现服务。实验容器测试不能替代此项实机记录。
- [ ] 使用可热插拔设备时，拔出后保持无输出、不改播到其他声卡；重插后如未恢复，重启容器验证恢复。
- [ ] 播放至少一小时，检查断音、CPU、内存、日志轮转和 `/data` 增长。

## 故障处置

接收进程异常后按有限退避重启；Pulse、内部模式的 D-Bus/Avahi 或 NQPTP 等核心进程退出时，容器退出，由生产 Compose 重启服务。外部模式不启动内部 D-Bus/Avahi，健康检查与监督器周期探测代理后的 Avahi；失联时监督器退出，由 Docker 重启音频服务。仅标记 unhealthy 不会触发 Docker 重启。

需要释放全部会话时，先停止客户端播放，再对 CLI 实例运行 `docker compose restart audio`（外部模式加上组合配置参数），或在 TrueNAS UI 中重启对应实例。这会中断全部会话并短暂重新广播服务；仍在主动重连的客户端可能再次成为 owner。

| 现象 | 定位与边界 |
| --- | --- |
| `.env` 校验失败 | 设置真实 `DATA_DIR` 和稳定 `AUDIO_DEVICE`；确认专用目录已存在。不要绕过必填保护改用宿主根目录。 |
| 容器循环退出 | 检查日志、设备是否存在及 UDP 319/320/9000 冲突；先 `docker compose stop audio`，修正后 `up -d`，无需清空数据。内部 Avahi 报 5353 占用时按下一行处理。 |
| Avahi 报 5353 已占用、无可用网络协议 | 只读确认占用进程及宿主 Avahi/D-Bus 状态；若 NAS Avahi 独占端口，采用[宿主 Avahi override](host-avahi.md)，不停止宿主服务、不改其 `disallow-other-stacks`。 |
| 外部模式代理不健康或 Avahi 不可达 | 检查宿主 `/run/dbus/system_bus_socket`、Avahi 服务、代理日志与组合后的挂载；只给代理原始宿主 socket。监督器会在周期探测失联后退出音频容器，单独 unhealthy 不会触发 Docker 重启。 |
| unhealthy 但仍运行 | Docker 不自动重启 unhealthy 容器；检查日志和 status，必要时手动 `restart audio`。 |
| 能发现但无声音 | 查看 owner、路由、客户端 URL 可达性、ALSA 名称、输出音量和音响输入设置。发现与音频可用是两件事。 |
| 发现不了设备 | 检查物理链路、客户端隔离、多播与接口选择；外部模式还受宿主 Avahi 接口允许/拒绝策略影响，`NETWORK_INTERFACE` 不会改变它。不要随意停用 NAS 自带发现服务。跨 VLAN 发现需要独立网络规划。 |
| 设备断开或格式不支持 | 不自动回退其他声卡；恢复设备后重启服务。如 ALSA 名称变化则重新探测并改配置。容器 /dev/snd 设备映射在热插拔后也可能需要重新创建。 |
| 旧手机反复重新接管 | 客户端在主动重新连接或播放；先在旧手机结束会话。协调器不能保证远程客户端不重试。 |
| 需要立即释放播放 | 按本节步骤停止客户端并重启服务；没有单独 release API，不用手动 pactl 删除模块伪装正常状态。 |

## 容器内访问与状态

PulseAudio 使用专用 `pulse` 系统账户，由 `dbus-run-session` 提供私有会话总线；HOME 和运行目录由该账户持有。Unix 音频 socket 仅供容器内访问，禁用未使用的 cookie 认证，动态模块加载用于音源切换。硬件模式按 `/dev/snd` 字符设备的实际组号授予访问权，无需放宽宿主 D-Bus 权限。相关验证见 [0.1.2 记录](verification-0.1.2.md)。

## 更新和回退

停止服务后用 TrueNAS 数据集快照或自己认可的备份方式备份专用 `/data`，保留 `.env`、Compose 和旧镜像。新镜像先在 `compose.test.yaml` 验证，再安排实际声卡验收。生产切换会中断会话。

```sh
# 将 CURRENT_VERSION 替换为当前实例实际使用的镜像版本（含自定义标签）。
docker image tag lan-audio-bridge:CURRENT_VERSION lan-audio-bridge:rollback
docker compose stop audio
# 构建/导入并验证更新镜像后：
docker compose up -d --force-recreate
```

需要回退时停止服务，将保留的镜像恢复原标签，再重新创建容器。若上游修改了缓存格式，使用停机前的数据快照；不要无依据清空全部缓存。CLI 命令适用于 CLI 部署，TrueNAS UI 管理的实例在 UI 中执行相应停止/重新部署动作。

外部模式升级或回退须同时核对 `audio` 与 `discovery-proxy` 的镜像和合并后的 YAML；不要将不支持 `AVAHI_MODE=external` 的旧镜像直接套用该 override。代理卷只保存运行 socket，不替代 `/data` 备份。升级后重新执行代理隔离、重连及客户端发现/播放验收。

`docker compose down` 删除容器和网络，生产 `/data` 绑定目录不会删除。不要用广泛的 Docker prune 或删除 NAS 数据集来处理单个服务故障。镜像构建失败、第三方云服务变化、手机私有协议变化和硬件不兼容均不能靠增加容器权限保证恢复。
