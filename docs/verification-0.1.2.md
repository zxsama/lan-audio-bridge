# 0.1.2 PulseAudio 启动修复验证

日期：2026-10-30。Windows / WSL Ubuntu 的隔离 Docker 环境，镜像 `lan-audio-bridge:0.1.2`。硬件模式与手机播放的验收单独记录。

## 修复

- Pulse 以专用非 root 用户运行，`dbus-run-session` 创建同用户的私有会话总线。HOME 与运行目录由 Pulse 用户持有，权限 0700。
- 保留音源切换所需的动态模块加载；不使用系统模式，也不通过降低日志级别消除警告。
- 原有容器内匿名 Unix socket 显式关闭未使用的 cookie 认证；发现代理仍只允许 root 访问，未放宽宿主 D-Bus。
- ALSA 模式使用实际传入字符设备的组号，避免宿主与镜像的 audio GID 不同导致无权打开设备。

## 已通过的软件验证

- 55 项标准库单元测试。
- `tests/pulse_startup.py`：实际 Pulse UID、私有总线连通、目录权限、无 cookie 连接、动态模块加载/卸载、启动日志无本次报告的警告。
- `tests/recovery.py`：实际 Pulse daemon 和会话包装进程分别退出后，监督器清理整个进程组；独立监督器测试在主容器持续运行时确认无残留。整应用退出、恢复、身份保留及 SIGTERM 正常结束均通过。
- `tests/integration.py`：六种音源接管方向、唯一输出路由、录音频谱隔离、无旧流回退；真实 DLNA Play/Pause/Seek/Stop。
- `tests/host_avahi.py`：external 模式上述启动验证、root-only 发现 socket、Pulse 用户访问被拒、发现与协议握手、代理及宿主 Avahi 故障恢复。fixture 宿主服务保持独立。

这些测试使用 null 输出，不代表 USB 光纤已出声；AirPlay 2 手机传音、QQ/网易云客户端兼容性和 Spotify 账号播放仍需相应客户端验收。

实现参考：[PulseAudio 17 启动逻辑](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/daemon/main.c)、[native 协议认证选项](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/pulsecore/protocol-native.c)、[dbus-run-session 生命周期](https://dbus.freedesktop.org/doc/dbus-run-session.1.html)。
