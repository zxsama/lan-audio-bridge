# 小米妙播与播放缓冲（0.2.1）

0.2.0 增加实验性 MiPlay 接收器。它接收音频并输出到 `miplay_bus`，由现有协调器送往唯一输出；不是只模拟一个设备名称。协议模块取自固定 MIT 版本 [CastFabric](https://github.com/DjangoAILab/CastFabric/tree/5b7733ee9185a85843606de6fe94867f7d5a42cf/miair/miplay)，本地修改和校验值随源码保留。

```text
小米手机 → MiPlay 控制/WFD RTSP → AAC 解码 → 48kHz 双声道 PCM
         → miplay_bus → 音源协调 → PulseAudio → USB 声卡 → 光纤
```

## 列表稳定性和空闲显示

0.2.1 将未认证连接的 15 秒握手期限与已认证连接的 120 秒闲置期限分开。手机发送完整合法心跳或查询会续期；未认证连接或只有零碎字节的连接不会无限保留。实际媒体传输继续使用独立媒体超时。

设备查询返回 idle=0、playing=2、paused=3，未开始接收媒体时保持 idle；另一条列表探测连接也会读取当前妙播会话的状态。0.2.0 把无媒体状态报成 paused，可能让手机显示“暂无歌名”占位。修复不靠空格或假标题遮盖界面，实际手机显示效果仍需更新后确认。

## 配置和发现

| 配置 | 默认值 | 含义 |
| --- | --- | --- |
| `ENABLE_MIPLAY` | `true` | 可独立关闭，不影响其他接收协议 |
| `MIPLAY_PORT` | `8899` | TCP 控制端口，与其他已开启接收器不同 |
| `DEVICE_NAME` | `NAS Audio` | 与其他协议使用同一显示名 |
| `NETWORK_INTERFACE` | 空 | 多网卡时建议明确指定手机所在 LAN 接口；指定后使用该接口 IPv4 |
| `DLNA_BUFFER_MS` | `1000` | DLNA 播放端 PCM 缓冲目标，范围 0–5000；0 回到上游默认值 |
| `OUTPUT_BUFFER_MS` | `200` | 各协议共同输出 loopback 的目标延迟，范围 50–1000 |

妙播沿用持久 UUID，调用现有 Avahi 的 EntryGroup API 发布 `_mi-connect._udp`，并绑定唯一主机名到选定 IPv4。外部 Avahi 模式继续使用现有受限代理，不需要放宽其权限，也不另起 mDNS 服务争用 5353。

广告中的 SRV 56666 是 MiConnect 身份结构的一部分；实际 TCP 控制端口在 `appsData`。当前不实现 UDP 56666 的 CoAP、旧版 UDP 5355 或 `_lyra-mdns` 发现。因此依赖这些路径的发送端可能不列出设备。本机模拟发送端验证不能代替具体小米手机和 HyperOS 版本验证。

媒体阶段由接收器反向连接手机提供的临时 TCP 端口，要求手机与 NAS 双向可达。控制断开、关闭命令或媒体故障释放会话。单个妙播会话播放时另一个妙播发送端不能并行混音；先断开旧会话再连接。其他协议新起播仍按现有规则接管，并重启被抢占的接收器。

## DLNA 流畅度

`DLNA_BUFFER_MS` 调整 GStreamer `pulsesink buffer-time`（内部单位微秒），缓冲解码后的 PCM，保留正常时钟同步和 Pause/Seek/Stop 行为。没有启用 gmrender 0.3 的网络 BUFFERING 状态机，避免其可能在用户暂停后自动恢复的问题。也不使用持续锁住储量的 queue 最小阈值。

默认 1 秒缓冲提高短时停供余量，可能增加起播和恢复等待。`OUTPUT_BUFFER_MS` 是另一段输出链路的调度余量，不等于网络缓存。无法用有限缓冲消除持续带宽不足、长时间断流、设备异常或所有 NAS 调度问题。真实现场卡顿原因尚未通过 NAS 日志/录音确认。

## 本机软件验证

使用 `compose.test.yaml` 的独立 bridge/null 输出实例，无宿主声卡和公开端口；不要向生产容器运行注入或故障测试。

```sh
docker build -t lan-audio-bridge:0.2.1 .
docker compose -f compose.test.yaml up -d --wait --wait-timeout 120
python3 tests/integration.py
python3 tests/discovery.py
python3 tests/dlna_jitter.py --format wav --label buffered
python3 tests/dlna_jitter.py --format flac --label buffered
```

完整单元和协议测试可在镜像内运行：

```sh
docker run --rm --network none -v "$PWD:/workspace:ro" --entrypoint python3 \
  lan-audio-bridge:0.2.1 -B -m unittest discover -s /workspace/tests -p 'test_*.py' -v
```

`tests/miplay_sender.py` 用同一固定版本的模拟发送端执行控制、RTSP 和 AAC 传输，并从真实 Pulse 输出录音。它不是手机应用，不证明独立实现之间的兼容性。执行时仅选择隔离 null 容器，目标地址为该测试容器的 bridge IPv4。

```sh
cid=$(docker compose -f compose.test.yaml ps -q audio)
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")
docker exec -i "$cid" python3 - --target "$ip" --source-address "$ip" --duration 4 < tests/miplay_sender.py
python3 tests/host_avahi.py --image lan-audio-bridge:0.2.1
docker compose -f compose.test.yaml down
```

TrueNAS 应用由用户通过原有界面更新。本轮仅准备源码、Compose 和本机镜像，没有远程导入、停止、重建或更新 NAS 应用。手机列表出现、选中播放、暂停恢复、断开重连，以及 USB 光纤实际听音须在用户部署后验收。
