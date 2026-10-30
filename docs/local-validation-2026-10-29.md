# 本机部署与软件验证（2026-10-29）

验证范围为 Windows/WSL 中的隔离软件环境，未连接 USB 音频硬件。结果不覆盖 TrueNAS 部署、手机互通或物理音频输出。

## 验证环境与部署检查

- Compose：`compose.local.yaml`，项目 `lan-audio-bridge-local`。
- 容器：`lan-audio-bridge-local-audio-1`。
- 镜像：`lan-audio-bridge:0.1.0`，ID `sha256:7fc707edf4b2148245a0ad5a94cb6cd83ac07aa22e619531be6e986982e121c6`。
- 使用独立 bridge、持久命名卷、`restart: unless-stopped`、null 音频输出。没有声卡映射。
- Windows 访问 `http://127.0.0.1:49494/description.xml` 返回 200。
- `scripts/local.ps1` 的 Start、重复 Start、Status、Stop、再次 Start 均通过。重复启动不重复保活；停止后保活退出，重启后 DLNA UUID 保留。
- 移除临时 WSL 保活会话后，75 秒后的复查显示同一个测试容器仍 healthy，重启次数为 0，HTTP 仍为 200；部署脚本创建的隐藏保活进程仍在运行。

Windows 重启或 WSL 被手动关闭后，需重新运行 `scripts/local.ps1 Start`；没有安装系统开机启动服务。具体操作见 [本机部署说明](local-deployment.md)。

## 已完成验证

| 项目 | 结果及证据范围 |
| --- | --- |
| 源码与运行镜像一致性 | runtime.py、healthcheck.py 的本地、镜像及测试容器 SHA256 一致 |
| 单元测试 | 46/46 通过 |
| 六向音源切换 | 全部通过；只有一个输出路由，迟到的旧流不会误释放当前音源 |
| 数字音频输出 | 实际录制 Pulse output.monitor，检查目标频率、左右声道、旧源隔离和空闲静音 |
| DLNA 真实播放 | HTTP WAV 经 renderer 解码输出，Play、Pause、Seek、Stop 全通过 |
| 异常恢复 | 三接收器实际被终止后恢复；Pulse 核心异常使容器非零退出；重启保留身份且空闲；正常 SIGTERM 停止通过 |
| 独立客户端发现 | 从另一个临时只读容器发送 mDNS 查询，获得 AirPlay、RAOP、Spotify 的 PTR/SRV/TXT/A；SSDP M-SEARCH 与广告的 DLNA 描述 URL 通过 |
| 连接接口 | AirPlay RTSP OPTIONS、/info 及 Spotify getInfo 通过；未覆盖 Spotify 账号授权与曲目播放 |
| 真实 AirPlay 音频 | 独立 pyatv 发送端使用公开的 ManualService/AirPlayVersion.V1 接口发送合成 WAV，原接收器解码后录音主频 440 Hz 幅度为 7177.9，660/880 Hz 分量分别为 30.97/17.16（均低于主频的 0.5%）；发送完成后路由回到空闲，未修改接收器配置 |

该版本新增独立发现检查、真实 AirPlay 发送检查和本机部署管理文件；验证未发现需要修改运行代码的新问题。

## 尚未覆盖的边界

- 上述实际 AirPlay 音频走 RAOP/AirPlay 1。pyatv 自动 AirPlay 2 的 SETUP 使用 NTP，当前 Shairport 对该路径返回 501，支持的 AirPlay 2 PTP 路径仍需真实手机验证；不能把 AirPlay 1 测试称为 AirPlay 2 传音通过。
- Spotify 仅验证发现和连接接口，未验证 Premium 授权与曲目播放。
- 验证环境的 WSL 使用 NAT。Docker 网络内的 mDNS/SSDP 成功，不证明手机能够跨 Windows/WSL 边界发现设备。
- 未验证 QQ 音乐/网易云的手机版本兼容性、受权限限制的曲目、USB 音频适配器的 UAC/采样率、USB 光纤出声或硬件重连。

详细命令输出保存在本地忽略目录 `test-results/`；它们不是公开发布文件。原验收方法见 [验证记录](verification.md)，真实传音方法和协议模式差异见 [AirPlay 发送测试](airplay-sender-validation.md)。
