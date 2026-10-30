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
compose.local.yaml    Windows/WSL 常驻软件演示
.env.example          生产配置模板，不含真实目录和设备标识
```

`compose.yaml`、`compose.test.yaml`、`compose.local.yaml` 各自独立，不要互相合并。只有 `compose.host-avahi.yaml` 是明确用于与生产 `compose.yaml` 合并的 override；不能将它套到 bridge 网络测试或本机演示上。测试使用专用项目与数据卷，不应指向生产容器。

## 单元测试

在项目目录使用 Python 3.11 或更新版本：

```sh
python3 -B -m unittest discover -s tests -p test_runtime.py -v
```

这组测试不需要 Docker、声卡、手机或服务账号。Windows 中可将 `python3` 换为 `python`。`-B` 避免生成 `__pycache__`。

## Docker 软件验证

在 Linux/WSL 项目目录构建并运行独立测试实例：

```sh
docker build -t lan-audio-bridge:0.2.0 .
docker compose -f compose.test.yaml config --quiet
docker compose -f compose.test.yaml up -d --wait --wait-timeout 120
python3 -B tests/integration.py
python3 -B tests/recovery.py
python3 -B tests/discovery.py
python3 -B tests/airplay_sender.py
docker compose -f compose.test.yaml down
```

`integration.py` 检查真实 PulseAudio 音频隔离和 DLNA 播放；`recovery.py` 会终止测试接收进程及核心进程，检查恢复和持久身份；`discovery.py` 从独立容器检查 mDNS、SSDP 与连接接口。`airplay_sender.py` 在临时容器安装固定版本的发送端依赖，发送 RAOP/AirPlay 1 音频，需要网络下载。测试失败后先保留日志并检查测试容器；无论结果如何，都应停止测试实例。

最后的 `down` 保留测试卷以便诊断；确认不再需要测试状态后可加 `--volumes`。这只用于 `compose.test.yaml`，不删除本机演示或生产数据。

软件验证不能代替 [真机验收](operations.md)。历史验证记录保留各自日期和镜像 ID；修改运行代码或依赖后，应重跑受影响的测试，而不是将旧记录当作新镜像的结果。

## 宿主 Avahi 模式验证

构建当前镜像后，可独立执行：

```sh
python3 -B tests/host_avahi.py --image lan-audio-bridge:0.2.0
```

该脚本在临时 Docker 网络命名空间中模拟独占 5353 的 Avahi、私有 D-Bus 和独立过滤代理，使用独立资源前缀并清理测试资源；不使用真实 host network、宿主 D-Bus、声卡、账号或发布端口。应检查代理访问限制、动态服务公告与失联恢复的实际输出。本节提供运行方法，不代表本轮脚本已通过；执行结果应单独记录。

通过隔离测试仍不能确认真实 NAS 的 D-Bus 策略、接口允许列表、手机发现或播放。宿主 Avahi 重启和代理重启后的重新公告也需按[外部发现验收](host-avahi.md)分别记录，不能套用旧内部 Avahi 测试结果。

## 本地文件与镜像范围

`.env`、`data/`、`test-results/`、`dist/`、`.serena/` 和 Python 缓存均被 Git 忽略。账号状态保存在部署的数据卷或目录中，不进入源码。原始日志分享前应另行检查；公开验证记录只保留必要结论与复现方法。

`.dockerignore` 使用白名单：构建只接收应用代码、两份容器内 shell 脚本、Dockerfile 和上游来源文档。Windows/WSL 管理程序、测试、交付归档和本机状态不会复制到运行镜像中。

## 0.2.0 回归

`test_runtime.py` 无需外部依赖；`test_miplay.py` 的完整协议测试需要镜像内依赖和 FFmpeg。缺依赖时会跳过相应项目，不能算完整通过。构建时验证 vendor SOURCE.json 中的 SHA256。

新增 `tests/dlna_jitter.py --format wav` 和 `--format flac`：在隔离 null 容器内模拟 HTTP 500ms 停顿，检查持续 PCM、路由和 Pause/Resume/Seek/Stop。`--label` 仅标记输出，`--container` 选择已经启动的隔离测试容器。妙播模拟发送测试见 [miplay.md](miplay.md)。
