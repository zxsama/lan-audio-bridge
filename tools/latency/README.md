# 延迟测量工具

这些工具用于测量和排查 Windows → NAS → 扬声器链路的延迟与断音，都不改变配置；NAS 端脚本只读取 `/proc`、`/sys` 和诊断状态文件。

## Windows（`windows/`）

| 脚本 | 测量范围 | 说明 |
| --- | --- | --- |
| `sender-segment.ps1` | 应用提交 → 发送端 loopback → 本机 UDP | 同一 QPC 时钟。会临时停止已安装的发送端，测完自动恢复。`-Period 128` 模拟低延迟播放器，`-Period 0 -BufferMs 10` 模拟普通共享模式播放器。 |
| `acoustic.ps1` | 应用提交 → NAS → 扬声器 → 麦克风 | 播放短噪声标记（默认 −8.7 dBFS、21 ms），下面叠加 −55 dBFS 背景音，使 NAS 保持在稳态；用麦克风采集包的 QPC 设备时间戳计时。`-MicName BRIO` 选择麦克风，`-Output` 保存 JSON。会从扬声器发出声音。 |
| `LatencyProbe.cs` | 上述脚本共用的探针 | `Run`、`RunVban`、`RunAcoustic` 三种测量。 |

声学结果包含 DAC、扬声器内部处理和约 3 ms/m 的空气传播，不能拆成单独环节；同一位置前后对比才有意义。

## NAS（`nas/`）

在 NAS 主机上用 `python3` 运行，或从其他电脑执行 `ssh nas 'python3 - 参数' < 脚本`。

| 脚本 | 用途 |
| --- | --- |
| `dac_stall.py --seconds 200 [--processes]` | 每约 10 ms 读取 DAC 硬件指针，报告设备少播超过 10 ms 的停顿和实际速率。`--processes` 同时列出每次停顿前 8 秒内新启动的进程。 |
| `cpu_freeze.py --seconds 130 --cpus 0,7,15,31` | 在指定核上各跑一个计时循环。只有部分核停顿说明那几个核上有中断或软中断负载；所有核同时停顿说明整机冻结（如 SMI）。每个核运行期间占满。 |
| `receiver_status.py --status <DATA_DIR>/diagnostics/status.json` | 接收端状态变化时打印一行：会话、欠载、服务器溢出、缓冲溢出、总延迟、调速。需要 `DIAGNOSTICS_STATUS=true`。 |

2026-11-08 正是用 `dac_stall.py --processes` 找到 DAC 每约 63 秒停顿一次的原因：NAS 上另一个容器在循环重启，每次重建网络都会引发大量 udev 事件。
