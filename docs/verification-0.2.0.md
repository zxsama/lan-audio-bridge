# 0.2.0 软件验证（2026-10-31）

验证环境为 Windows / Ubuntu WSL 中的 Docker，通过本地 Unix socket 连接。所有音频注入和故障测试均使用独立 bridge 网络、null 输出，无 `/dev/snd` 和公开端口；结果不覆盖 TrueNAS 部署或物理音频输出。

## 实现

- 新增实验性 MiPlay 接收通道：固定版本协议模块、Avahi 代理公告、控制/WFD/RTSP/AAC 解码、独立 Pulse 总线和原有音源协调。
- 会话 CLOSE、控制连接断开、RTSP/解码/PCM 输出失败均回收资源；暂停关闭音频输入并继续消费/丢弃 PCM，恢复重新创建输入。新会话音量与其公布初值一致。
- DLNA 使用 `pulsesink buffer-time=1000000`，保留正常时钟同步；`DLNA_BUFFER_MS=0` 可回到上游默认。共同输出目标延迟从 100ms 调整为默认 200ms，可通过 `OUTPUT_BUFFER_MS` 设置。
- 不启用 gmrender 的网络 BUFFERING 状态机；不改变宿主调度、网络或 D-Bus 权限。

## 已完成检查

| 检查 | 结果 |
| --- | --- |
| 镜像构建 | 成功；检查 MiPlay 依赖导入与 vendor 文件 SHA256 |
| 完整单元/协议测试 | 82 项通过，无依赖跳过；含真实 TCP/RTSP/AAC、故障清理、保持媒体连接时的关闭/断开、暂停恢复、音量重置 |
| 独立运行 MiPlay → Pulse 输出 | 4 秒 paced 模拟音源；控制和 RTSP 成功，62 个媒体帧，实际输出获得 3.9 秒连续 997Hz；54 次检查确认唯一 MiPlay 路由；结束后 idle、无遗留 ffmpeg/pacat |
| 四音源协调 | 12 个有向接管组合通过；实际录音检查当前音源、其他频率隔离、旧流结束不误释放新 owner、无旧音源自动恢复 |
| DLNA 控制 | 真实 SOAP Play/Pause/Seek/Resume/Stop 及播放进度检查通过 |
| 发现 | 独立容器确认 AirPlay/RAOP/Spotify/MiPlay 的 PTR/SRV/TXT/A、DLNA SSDP，以及公告控制端点可达 |
| 外部 Avahi | 在隔离模拟宿主中复现独占 5353；代理发布正常、限制保持；代理和 Avahi 分别重启后恢复公告，模拟宿主服务不被接收器修改 |
| 故障恢复 | 四个接收器分别异常退出后重启；真实 Pulse daemon/wrapper 失败退出、持久身份保留、重启空闲和 SIGTERM 清理全部通过 |
| Compose | 独立测试配置和生产+host-avahi 合并配置语法校验通过，未据此启动生产部署 |

单位测试命令：

```sh
docker run --rm --network none -v "$PWD:/workspace:ro" --entrypoint python3 \
  lan-audio-bridge:0.2.0 -B -m unittest discover -s /workspace/tests -p 'test_*.py' -q
```

## DLNA 卡顿对照

同一隔离环境，合成媒体通过 HTTP 按播放速度发送，每 3 秒暂停发送 500ms，之后追赶，避免测试退化为持续带宽不足。记录真实 `output.monitor`，以 50ms 窗口检查音量与目标频率，并检查 owner/单一路由。稳态连续录音 12 秒，另检查暂停期间网络恢复、恢复播放、Seek 后首次停供和停止静音。

| 情况 | 稳态音频缺口 | Seek 后观察段最大缺口 | 暂停/恢复/停止 |
| --- | --- | --- | --- |
| 0.1.2 原配置，WAV | 0 | 350ms | 控制状态正常；Seek 后声音不连续 |
| 0.2.0 默认缓冲，WAV | 0 | 0 | 通过 |
| 0.2.0 默认缓冲，FLAC | 0 | 0 | 通过 |

新配置的 WAV、FLAC 各经历 11 次 HTTP 停顿，其中稳态窗口内各 4 次；稳态、恢复和 Seek 观察段均没有低于判定阈值的音频窗口，路由无异常反复重建。暂停和停止后输出静音。

这些结果表明新的播放端缓冲改善了此可重复的短时供给不足场景，不构成部署环境中卡顿原因的诊断，也不承诺抵御任意时长断流。该测试为平稳合成音，不能覆盖全部云端媒体、VBR 文件或毫秒级样本连续性。

## 交付与未验证项

本机镜像：`lan-audio-bridge:0.2.0`。源码 Compose 使用本地镜像并保持 `pull_policy: never`，不会假定公网存在该镜像。

最终镜像 ID：`sha256:1a45f8e06711c9e0abb11c914573fcd5ff7b921a960d51a2c6a8e448472af4f7`。
本机导出文件 `dist/lan-audio-bridge-0.2.0.tar`（不进入 Git），SHA256：`8532f33bc77c43164b443f2d9eaa5e451b6956eb52b68f5c8da9e09e20170861`。

`compose.local.yaml` 的 0.2.0 演示部署检查通过：状态 healthy，Windows 的 localhost DLNA 描述接口可达。该实例使用 null 输出，结果不代表手机可以通过 Windows/WSL 网络发现它。

该版本的验证未覆盖真实小米手机/HyperOS；实现范围为 `_mi-connect._udp` + TCP/WFD/AAC 路径，不含 CoAP、旧版 5355 和 `_lyra-mdns`。模拟发送端与接收器复用固定版本协议定义，不能作为独立手机互通证明。AirPlay 2 手机传音、Spotify 账号播放和 USB 光纤实际听音也不在该版本的验证范围内。

本记录仅覆盖软件构建和隔离验证，TrueNAS 部署需另行验收。原始测试结果保存在被 Git 忽略的 `test-results/`；公开文档仅保留必要结果与复现方法。
