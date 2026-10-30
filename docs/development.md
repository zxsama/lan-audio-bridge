# 开发与测试

本项目运行层只使用 Python 标准库；音频与协议依赖由 Dockerfile 安装。生产目标为 Linux amd64。Windows 本机部署通过 Ubuntu WSL 使用 Docker，见 [本机部署说明](local-deployment.md)。

## 目录

```text
app/                  运行时监督器、音源协调器与健康检查
scripts/              主机检查、状态查询和 Windows/WSL 本机管理
tests/                单元测试、音频集成、恢复、发现与 RAOP 发送测试
docs/                 设计、运行约定、部署运维和历史验证记录
Dockerfile            固定上游版本的多阶段镜像构建
compose.yaml          NAS 实际声卡部署
compose.test.yaml     隔离的 null 输出测试实例
compose.local.yaml    Windows/WSL 常驻软件演示
.env.example          生产配置模板，不含真实目录和设备标识
```

三个 Compose 文件各自独立，不要使用多个 `-f` 将它们合并。测试使用专用项目与数据卷，不应指向生产容器。

## 单元测试

在项目目录使用 Python 3.11 或更新版本：

```sh
python3 -B -m unittest discover -s tests -p test_runtime.py -v
```

这组测试不需要 Docker、声卡、手机或服务账号。Windows 中可将 `python3` 换为 `python`。`-B` 避免生成 `__pycache__`。

## Docker 软件验证

在 Linux/WSL 项目目录构建并运行独立测试实例：

```sh
docker build -t lan-audio-bridge:0.1.0 .
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

## 本地文件与镜像范围

`.env`、`data/`、`test-results/`、`dist/`、`.serena/` 和 Python 缓存均被 Git 忽略。账号状态保存在部署的数据卷或目录中，不进入源码。原始日志分享前应另行检查；公开验证记录只保留必要结论与复现方法。

`.dockerignore` 使用白名单：构建只接收应用代码、两份容器内 shell 脚本、Dockerfile 和上游来源文档。Windows/WSL 管理程序、测试、交付归档和本机状态不会复制到运行镜像中。
