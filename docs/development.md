# 开发与测试

监督器使用 Python 标准库；妙播适配层另用 Debian 提供的 D-Bus、Zeroconf 数据类型和加密包，音频依赖由 Dockerfile 安装。生产目标为 Linux amd64。Windows 本机部署通过 Ubuntu WSL 使用 Docker，见 [本机部署说明](local-deployment.md)。

## 目录

```text
app/                  运行时监督器、音源协调器与健康检查
scripts/              主机检查、状态查询和 Windows/WSL 本机管理
tests/                单元测试、音频集成、恢复、发现与 RAOP 发送测试
docs/                 设计、运行约定、部署运维和历史验证记录
Dockerfile            固定上游版本的多阶段镜像构建
compose.yaml          NAS 实际声卡部署
compose.host-avahi.yaml 生产配置专用的宿主 Avahi override
compose.test.yaml     隔离的 null 输出测试实例
compose.desktop-test.yaml  独立的 VBAN 与混音测试实例
compose.local.yaml    Windows/WSL 常驻软件演示
.env.example          生产配置模板，不含真实目录和设备标识
```

`compose.yaml`、`compose.test.yaml`、`compose.local.yaml` 各自独立，不要互相合并。只有 `compose.host-avahi.yaml` 是明确用于与生产 `compose.yaml` 合并的 override；不能将它套到 bridge 网络测试或本机演示上。测试使用专用项目与数据卷，不应指向生产容器。

Windows 本机演示使用 `scripts/local.ps1 Start / Status / Stop` 管理独立的 `compose.local.yaml` null 输出实例，操作步骤见[本机部署说明](local-deployment.md)。演示与测试实例分离，其状态不能替代手机局域网发现或 物理音频输出验证。

## 单元测试

在项目目录使用 Python 3.11 或更新版本：

```sh
python3 -B -m unittest discover -s tests -p test_runtime.py -v
```

这组测试不需要 Docker、声卡、手机或服务账号。Windows 中可将 `python3` 换为 `python`。`-B` 避免生成 `__pycache__`。

## Docker 软件验证

测试配置使用 bridge 网络、独立 Docker volume 和 null 输出，不映射 `/dev/snd`，不发布端口，也不会播放到真实声卡。在 Linux/WSL 项目目录构建并运行独立测试实例：

```sh
docker build -t lan-audio-bridge:0.3.0 .
docker compose -f compose.test.yaml config --quiet
docker compose -f compose.test.yaml up -d --wait --wait-timeout 120
python3 -B tests/integration.py
python3 -B tests/pulse_startup.py
python3 -B tests/recovery.py
python3 -B tests/discovery.py
python3 -B tests/airplay_sender.py
docker compose -f compose.test.yaml down
```

集成与恢复测试使用 Python 标准库和本地 Docker CLI：

- `integration.py` 向真实 PulseAudio 四个输入总线注入不同频率音频，在 `output.monitor` 录音并检查唯一音源，再通过 DLNA SOAP 验证 HTTP WAV 播放、暂停、Seek 和停止。
- `recovery.py` 主动终止测试接收进程和 Pulse 进程，检查监督重启、核心故障退出、容器重启后的持久身份与空闲状态，以及正常停止；仅针对独立 null 输出测试实例运行。
- `discovery.py` 从独立容器检查 mDNS、SSDP 与公告端点。
- `airplay_sender.py` 在临时容器下载固定版本发送端依赖，发送 RAOP/AirPlay 1 音频，完成后自动清理；不代表 AirPlay 2 传音通过，见 [AirPlay 发送测试](airplay-sender-validation.md)。

测试失败后先保留日志并检查测试容器；无论结果如何，都应停止测试实例。

最后的 `down` 保留测试卷以便诊断；确认不再需要测试状态后可加 `--volumes`。这只用于 `compose.test.yaml`，不删除本机演示或生产数据。

软件验证证明容器内管线与恢复行为，不能证明 iPhone AirPlay 2、Spotify 账号、QQ 音乐 QPlay、NAS 多播或 实际音频输出可用，也不能代替[真机验收](operations.md)。历史验证记录保留各自日期和镜像 ID；修改运行代码或依赖后，应重跑受影响的测试，而不是将旧记录当作新镜像的结果。

## 宿主 Avahi 模式验证

构建当前镜像后，可独立执行：

```sh
python3 -B tests/host_avahi.py --image lan-audio-bridge:0.3.0
```

该脚本在临时 Docker 网络命名空间中模拟独占 5353 的 Avahi、私有 D-Bus 和独立过滤代理，使用独立资源前缀并清理测试资源；不使用真实 host network、宿主 D-Bus、声卡、账号或发布端口。应检查代理访问限制、动态服务公告与失联恢复的实际输出。本节提供运行方法，各版本的执行结果见相应验证记录；新的执行结果应单独记录。

通过隔离测试仍不能确认真实 NAS 的 D-Bus 策略、接口允许列表、手机发现或播放。宿主 Avahi 重启和代理重启后的重新公告也需按[外部发现验收](host-avahi.md)分别记录，不能套用旧内部 Avahi 测试结果。

## 本地文件与镜像范围

`.env`、`data/`、`test-results/`、`dist/`、`.serena/` 和 Python 缓存均被 Git 忽略。账号状态保存在部署的数据卷或目录中，不进入源码。原始日志分享前应另行检查；公开验证记录只保留必要结论与复现方法。

公开文档、配置示例和代码注释使用通用设备描述与明确标注的示例值，不包含私人采购链接、个人路径、实际网络地址、设备身份或对话记录。上游来源、许可证署名和协议常量应保持准确；验证记录应注明版本和证据范围。

`.dockerignore` 使用白名单：构建只接收应用代码、两份容器内 shell 脚本、Dockerfile、项目许可证、第三方声明和上游来源文档。Windows/WSL 管理程序、测试、交付归档和本机状态不会复制到运行镜像中。

## 0.2.0 回归

`test_runtime.py` 无需外部依赖；`test_miplay.py` 的完整协议测试需要镜像内依赖和 FFmpeg。缺依赖时会跳过相应项目，不能算完整通过。构建时验证 vendor SOURCE.json 中的 SHA256。

新增 `tests/dlna_jitter.py --format wav` 和 `--format flac`：在隔离 null 容器内模拟 HTTP 500ms 停顿，检查持续 PCM、路由和 Pause/Resume/Seek/Stop。`--label` 仅标记输出，`--container` 选择已经启动的隔离测试容器。妙播模拟发送测试见 [miplay.md](miplay.md)。

0.2.1 增加 `tests/test_miplay_presence.py` 的真实 TCP 超时/状态回归，以及 `python3 tests/miplay_presence.py` 的独立容器 40 秒持续发现检查。后者仅发送认证、心跳和查询，不发送 OPEN、不播放媒体；要求已启动独立 `compose.test.yaml`，自动清理观察者。见 [0.2.1 验证](verification-0.2.1.md)。

0.2.2 增加 `tests/test_miplay_volume.py` 的跨连接音量和并发等待回归，以及 `tests/miplay_volume.py` 的真实服务/输入总线一致性检查。`integration.py` 同时验证输出挂起、恢复和 70%/100% 的实际幅度差异。测试方法与结果见 [0.2.2 验证](verification-0.2.2.md)。

## VBAN 与双路混音

`test_vban.py` 验证 PCM 包解析、源地址与流名匹配、序列及空闲生命周期。`test_runtime.py` 同时覆盖双路路由、握手状态与增益。以下测试使用已构建的 0.3.0 镜像：

```sh
docker compose -f compose.desktop-test.yaml up -d --wait --wait-timeout 120
docker exec lan-audio-bridge-desktop-test-audio-1 python3 /workspace/tests/desktop_audio.py --inside
docker exec lan-audio-bridge-desktop-test-audio-1 python3 /workspace/tests/desktop_latency.py --markers 30
docker exec lan-audio-bridge-desktop-test-audio-1 python3 /workspace/tests/desktop_recovery.py
docker compose -f compose.desktop-test.yaml down
```

该独立配置在容器内发送 UDP VBAN 音频，并录制 `output.monitor`。验证电脑单独输出、与四手机总线混音、十二种手机切换、独立停止与音量、短提示音恢复和数字静音挂起。它不会安装 Windows 驱动或向物理设备播放。软件链路延迟与真实 Windows 到音响的端到端延迟须分别报告。

0.3.0 的本机验证结果及延迟测量范围见 [0.3.0 验证](verification-0.3.0.md)。

## Windows 配置脚本

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-audio.Tests.ps1
pwsh -NoProfile -File tests/windows-audio.Tests.ps1
```

测试使用模拟 Remote API 检查参数、槽位、读回失败及恢复相关逻辑，不安装驱动、不切换真实设备、不写登录启动项。安装包 SHA256 与签名可单独验证，不能代替真实安装、重启续配和 Windows 到接收端的播放验收。`Plan` 与 `Status` 可用于不改变音频路由的本机检查。

2026-11-06 在 Windows PowerShell 5.1 和 PowerShell 7 中各通过 38 项测试，包括隔离执行生产脚本的安装、重启门禁及配置事务。官方 1.1.3.0 安装包的 SHA256、发布者签名和归档结构已验证；C# 互操作编译、真实端点枚举和默认设备接口查询通过，检查前后默认播放设备与启动项一致。未执行真实驱动安装、重启续配或改变默认设备，尚未完成 Voicemeeter 到实际接收设备的播放和延迟验收。
