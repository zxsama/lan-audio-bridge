# 本地验证记录

日期：2026-10-28。环境：Windows 主机的 WSL Ubuntu、Docker 28.1.1；测试服务使用独立 bridge 网络、null 输出，不映射 `/dev/snd`，没有操作 TrueNAS 或音箱。

本轮集成使用镜像 `lan-audio-bridge:0.1.0`，当时 image ID 为 `sha256:37f77cc31e3b5f1205a4411d19131cb38d45661cb1416000104cb88aca0b7b3c`。最终导出镜像 ID 为 `sha256:7fc707edf4b2148245a0ad5a94cb6cd83ac07aa22e619531be6e986982e121c6`：后续仅补充了检查脚本的 UDP 9000 端口提示和构建来源文档，应用层与依赖不变。已逐文件比较最终镜像与通过测试容器内的 runtime.py、healthcheck.py SHA256，完全一致。以后修改运行代码或依赖并重建时，应重跑对应检查。

| 验证项 | 本地结果 |
| --- | --- |
| 单元测试 | 46 项通过（Windows Python 与 WSL Python）；涵盖配置、六向切换、迟到事件、流状态、路由拒绝与清理、监督器退避、时钟服务就绪和健康检查 |
| 生产/测试 Compose 解析 | 通过；生产缺少 AUDIO_DEVICE/DATA_DIR 时拒绝解析；显式参数渲染保留 host network 与绑定目录保护 |
| probe/status shell 语法、集成脚本 Python 编译 | 通过 |
| 三接收器与核心服务健康启动 | 通过；使用 cap_drop ALL 和列出的能力，无 privileged |
| 三来源六个方向的接管 | 通过；向真实 Pulse 总线注入 440 / 660 / 880 Hz 双声道信号 |
| 唯一路由 | 每次接管状态中仅一个 loopback 和一个通往 output 的 sink-input，模块归属匹配；空闲时均无 |
| 数字音频隔离 | 每次接管后录制 output.monitor；稳定半秒片段主音约 10000，其他来源频率幅度低于 1.1，左右声道一致；阈值为主音幅度的 3% |
| 迟到的旧流结束、当前流停止 | 旧流结束未误释放新 owner；当前流停止后无自动回退，采样保持静音 |
| 真实 DLNA 控制与解码 | description.xml → AVTransport → HTTP WAV → Play → Pause → Seek 至 10 秒 → Play → Stop 全链通过；恢复播放位置与 520 Hz 实际输出均检查 |
| 三接收器崩溃恢复 | 独立 recovery 测试分别对三接收器实际发送 SIGKILL，监督器均重新启动 |
| Pulse 核心异常 | 终止 Pulse 后容器以非零状态退出；测试配置不自动重启，便于核对退出结果 |
| 重启与持久状态 | 重启保留 DLNA UUID 与 machine ID，启动后无 owner、无输出路由 |
| 正常停止 | SIGTERM 正常退出，随后可恢复启动 |

集成测试在实跑中暴露并修复了 PulseAudio 17 返回 sink-input `owner_module` 为字符串的问题。协调器现在先严格校验并归一化类型，再比对自己创建的模块 ID；实际未知来源直达 output 的防护仍需保留。

测试脚本通过 stdin 在容器内执行，避免 Docker 向 tmpfs 复制文件在该 WSL 环境中表现不一致。WSL 在没有前台会话时可能自动退出；本地验证期间应保持一个 WSL 会话运行。NAS 的长期运行不由这个 WSL 行为推断。

采样与路由检查发生在各次接管稳定后，证明这些片段只有一个数字音源；它不是对切换瞬间每一个采样、物理光纤波形或整段听感的测量。AirPlay 2 手机实际连接、Spotify Premium 授权播放、QQ 音乐 QPlay、NAS 多播发现、京像适配器 Linux/UAC/采样率以及音箱出声仍属于 [真机验收清单](operations.md)，本地结果不能替代。

核心进程故障恢复与持久身份检查由独立 `python3 tests/recovery.py` 执行；上述结果由主任务在同一 null 输出测试实例实跑通过。该测试会中断测试会话，不应针对生产硬件实例执行。
