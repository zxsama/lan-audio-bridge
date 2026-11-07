# 0.1.2 PulseAudio 启动修复验证

日期：2026-10-30。Windows / WSL Ubuntu 的隔离 Docker 环境，镜像 `lan-audio-bridge:0.1.2`。硬件模式与手机播放的验收单独记录。

## 修复

- Pulse 以专用非 root 用户运行，`dbus-run-session` 创建同用户的私有会话总线。HOME 与运行目录由 Pulse 用户持有，权限 0700。
- 保留音源切换所需的动态模块加载；不使用系统模式，也不通过降低日志级别消除警告。
- 原有容器内匿名 Unix socket 显式关闭未使用的 cookie 认证；发现代理仍只允许 root 访问，未放宽宿主 D-Bus。
- ALSA 模式使用实际传入字符设备的组号，避免宿主与镜像的 audio GID 不同导致无权打开设备。

## 已通过的软件验证

- 55 项标准库单元测试。
- `tests/pulse_startup.py`：实际 Pulse UID、私有总线连通、目录权限、无 cookie 连接、动态模块加载/卸载、启动日志无系统模式、HOME、cookie 或 D-Bus 访问警告。
- `tests/recovery.py`：实际 Pulse daemon 和会话包装进程分别退出后，监督器清理整个进程组；独立监督器测试在主容器持续运行时确认无残留。整应用退出、恢复、身份保留及 SIGTERM 正常结束均通过。
- `tests/integration.py`：六种音源接管方向、唯一输出路由、录音频谱隔离、无旧流回退；真实 DLNA Play/Pause/Seek/Stop。
- `tests/host_avahi.py`：external 模式上述启动验证、root-only 发现 socket、Pulse 用户访问被拒、发现与协议握手、代理及宿主 Avahi 故障恢复。fixture 宿主服务保持独立。

以上隔离测试使用 null 输出，不代表 USB 光纤已出声；AirPlay 2 手机传音、QQ/网易云客户端兼容性和 Spotify 账号播放仍需相应客户端验收。

## TrueNAS 设备验证

2026-10-30，在 TrueNAS 的 USB 声卡环境中完成应用更新与启动检查。验证镜像与隔离软件测试一致：`sha256:c7e5cef5f341fb4ccdcb5415c144939404cf8f97e5441b3d5759c27c4f319972`。以下仅记录该版本的硬件初始化结果。

- 音频与发现代理两个容器均为 running / healthy，重启次数为 0，健康检查退出码为 0。
- 实际 Pulse、会话包装进程、私有 dbus-daemon 均为 UID 101；音频设备附加组已生效。
- 新容器启动日志只有 Pulse、NQPTP、AirPlay、DLNA、Spotify 启动记录，没有系统模式、HOME、cookie 或 D-Bus 访问警告。五个子服务均运行，重启次数为 0。
- `module-alsa-sink` 成功打开配置的 USB 声卡；Pulse 报告 `s24le 2ch 48000Hz`，宿主 ALSA `hw_params` 为 S24_3LE、2 声道、48000 Hz。
- 验证时输出为 idle / mute、无活动音源；宿主 Avahi 进程 PID 与更新前一致。

这确认真实 USB 声卡可被新运行身份打开，不代表音箱实际出声、手机传音或整条链路 bit-perfect 已验收。

实现参考：[PulseAudio 17 启动逻辑](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/daemon/main.c)、[native 协议认证选项](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/pulsecore/protocol-native.c)、[dbus-run-session 生命周期](https://dbus.freedesktop.org/doc/dbus-run-session.1.html)。
