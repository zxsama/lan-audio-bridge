# Windows 本机软件演示部署

此部署用于本机 Docker 软件验证，不访问真实声卡。当前配置要求 Ubuntu WSL 中已有 `lan-audio-bridge:0.2.0` 镜像，固定 `AUDIO_MODE=null`，不会向 Windows 或 USB 声卡输出声音，也不能据此确认光纤音频可用。更新配置前先构建或导入对应镜像；历史验证记录中的旧镜像版本保持原样。

在 Windows PowerShell 中切换到本项目目录：

```powershell
./scripts/local.ps1 Start
./scripts/local.ps1 Status
Invoke-WebRequest -Uri 'http://127.0.0.1:49494/description.xml' -UseBasicParsing
./scripts/local.ps1 Stop
```

`Start` 等待容器健康（最多 120 秒）后返回，可重复运行。`Status` 显示容器和本实例 WSL 保活进程。`Stop` 删除本实例容器及网络，保留 `lan-audio-bridge-local_local-data` 卷；下次启动会保留 DLNA 身份等状态。脚本没有自动安装 Docker 或加载镜像，需要 Ubuntu WSL、Docker Compose、Python 3 和现有镜像就绪。端口冲突、镜像缺失或健康检查失败时直接报错，不会终止其他服务。

`compose.local.yaml` 是独立配置，不和 `compose.yaml`、`compose.test.yaml` 合并。项目名固定为 `lan-audio-bridge-local`；容器为 `lan-audio-bridge-local-audio-1`，网络为 `lan-audio-bridge-local_default`。它使用 bridge 网络、独立命名卷、原有最小 capabilities、健康检查和 `restart: unless-stopped`；没有 `/dev/snd`、Docker socket 或宿主目录挂载。

本机演示继续使用默认 `AVAHI_MODE=internal`。`compose.host-avahi.yaml` 只为实际 Linux NAS 的 host-network 生产配置提供外部发现，不适用于本页的 bridge 网络，也不要挂载 Windows/WSL 宿主 D-Bus 来替代本机演示配置。其隔离软件验证另见[开发文档](development.md)。

只有 DLNA TCP 49494 发布到 WSL 的 `127.0.0.1:49494`。当前 Windows 可通过 WSL localhost 转发读取设备描述；这只是本机 HTTP 可达验证。没有发布 AirPlay/Spotify 端口，也没有为手机配置局域网广播、多播或访问入口。默认 WSL NAT 环境下，容器健康和 Windows 能读取描述均不证明手机发现、AirPlay 2、Spotify 授权或 QQ 音乐/QPlay 可用。手机和硬件验收仍按 [运维文档](operations.md) 在实际局域网及设备上完成。

## WSL 生命周期

本机 WSL 在没有前台会话时可能退出。`Start` 用隐藏窗口启动一个限定于本实例的 Python 保活进程；它每两秒只读检查目标容器，通过进程锁避免重复启动。容器删除、停止、Docker 查询失败或超时后退出；连续 restarting 超过 60 秒也退出。`Stop` 等待该进程自行退出，不执行 `wsl --terminate`、`wsl --shutdown`，不结束其他 WSL 会话。

这没有安装 Windows 服务或计划任务，也不改变防火墙、WSL 全局配置。重启 Windows、手动关闭 WSL 后，需要再次运行 `Start`。Docker 的容器重启策略只在 Docker/WSL 存活时生效；健康状态变为 unhealthy 本身不触发重启。保活退出后可运行 `Status` 排查，再用 `Start` 恢复；脚本不会无限尝试启动失败的保活程序。

日志及实际运行参数可只读查看：

```powershell
$root = (wsl -d Ubuntu -u root -- wslpath -a (Get-Location).Path.Replace('\', '/')).Trim()
wsl -d Ubuntu -u root -- docker compose -p lan-audio-bridge-local -f "$root/compose.local.yaml" logs --tail 100 audio
wsl -d Ubuntu -u root -- docker inspect lan-audio-bridge-local-audio-1
```

日志和卷可能包含协议会话状态，分享前自行检查并脱敏。日常停止使用 `Stop` 即可，不需要删除数据卷。
