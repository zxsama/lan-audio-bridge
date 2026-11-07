# 0.1.1 发现服务冲突修复验证

日期：2026-10-30。软件验证环境为 Windows 的 Ubuntu WSL / Docker，使用隔离 bridge、null 音频输出和专用测试卷，不访问 NAS 的 D-Bus、网络命名空间或声卡。

原问题是在 host network 下，宿主 Avahi 已占用 UDP 5353，音频容器内的第二个 Avahi 绑定失败，导致核心服务退出及反复重启。0.1.1 提供外部 Avahi 模式和独立 D-Bus 代理。

## 已通过的检查

- 53 项单元测试：包含外部模式配置、避免启动第二套发现服务、外部服务失联、健康检查和原有音频协调规则。
- Docker 构建：安装 `xdg-dbus-proxy 0.1.6-1+deb13u3`，通过最低发行版修复版本检查。
- internal 模式集成：六向音源接管、唯一输出路由、实际数字录音、空闲静音、DLNA Play/Pause/Seek/Stop。
- internal 恢复：三接收器退出后重启、Pulse 核心失败使容器非零退出、重启保留身份、SIGTERM 正常停止。
- internal 发现：独立容器检查 AirPlay/RAOP/Spotify mDNS、SSDP、RTSP `/info` 及 Spotify getInfo。
- `tests/host_avahi.py`：在模拟宿主 Avahi 独占 5353 时，internal 模式复现失败；external 模式健康并完成上述发现及连接接口检查。
- 代理隔离：audio 没有原始宿主总线挂载；无关 D-Bus 服务、RequestName、Avahi SetHostName 请求被拒绝；宿主名称和服务保持不变。
- 故障恢复：停止测试代理或测试 Avahi 后，audio 健康检查失败并非零退出；恢复代理/Avahi 并重启 audio 后，三协议发现和连接接口重新通过。测试使用 `restart=no` 观察退出，再显式重启；生产配置使用 `unless-stopped`。
- audio 停止不终止模拟宿主的 D-Bus 或 Avahi；测试资源完成后清理。

复现命令见 [开发文档](../development.md) 和 [宿主 Avahi 部署说明](../host-avahi.md)。RAOP/AirPlay 1 的历史验证不构成新模式下的手机 AirPlay 2 验收，也不代表 Spotify 账号传音或 USB 光纤出声已经通过。

## NAS 应用更新要求

修改共享目录 YAML 不会替换既有容器镜像。新 YAML 的 `discovery-proxy` 需要包含 `/app/avahi_proxy.py` 的 0.1.1 镜像；如果出现该文件不存在，需重新构建或导入完整新镜像，然后重新部署。仅重启旧容器不能补入该文件。
