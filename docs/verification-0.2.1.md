# 0.2.1 妙播列表与空闲状态修复（2026-10-31）

用户反馈：NAS Audio 可显示和选择，但偶尔从手机妙播面板消失，重新进入面板会再次显示，应用界面没有对应重启日志；空闲 NAS Audio 还显示“暂无歌名”副标题。

## 已定位的问题和修复

1. **设备列表探测连接被握手期限误关闭。** 0.2.0 只有创建媒体 WFD 任务后才退出建连时的 15 秒期限；认证成功、持续发送心跳或状态查询仍会在期限到达时关闭 TCP。它不会导致接收器进程重启，所以不一定出现监督器的 started/unavailable 日志。现改为：未认证连接保持固定 15 秒握手期限；认证后的无媒体控制连接使用独立 120 秒闲置期限，每个完整且接受的命令续期。零碎字节不续期，真正闲置连接仍释放。
2. **空闲设备被上报为暂停媒体。** 0.2.0 把尚未收到媒体和真正暂停都返回为状态 3；媒体信息同时为空，容易触发手机的无标题占位。现明确区分 idle=0、playing=2、paused=3。独立列表探测连接读取活跃妙播会话的状态，首次媒体之前以及会话清理后为 idle，不伪造空格或假歌名。

状态值依据公开接收器记录中的 MiPCAudio pre-OPEN idle=0、playing=2、paused=3，以及[小米 SDK 的状态定义](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1911)佐证。音频线协议参考为 [FusionPlay protocol.rs](https://github.com/rosienosiesie/FusionPlay-Android/blob/main/src/FusionPlay.MiPlaySdk/src/protocol.rs)，仅参考协议事实，没有复制其实现代码。固定 MIT vendor 的本地修改和 SHA256 已更新。

本次没有改动 Avahi 发布方式、系统权限、DLNA 缓冲、媒体结束或 CLOSE 清理语义；跨协议接管仍按原规则重启被抢占的接收器并短暂重新公告。

## 本机验证

所有测试在本机 Windows/WSL 或本机 Docker 的独立 bridge/null 环境进行，没有操作 TrueNAS Docker、播放真实声卡或修改 NAS 应用。

| 检查 | 结果 |
| --- | --- |
| 旧版问题复现 | 将握手期限缩为 0.15 秒，真实 TCP 认证后每 0.06 秒发送心跳，旧代码仍关闭连接；修复后通过 |
| 完整单元/协议测试 | Docker 中 91 项通过，无依赖跳过 |
| 新增 9 项回归 | 认证后续期、真正闲置过期、未认证过期、分片和无效帧边界、探测不建 PCM、独立探测的 0→2→3→2→0 状态一致性；active WFD 不被控制闲置期限中断 |
| 独立容器持续观察 | 认证后 40.003 秒，同一连接 17 组心跳/状态查询，idle 始终为 0；9 次重新创建的 mDNS 解析成功 |
| 进程/音频稳定性 | 19 次采样确认容器与接收器 PID 不变、重启次数 0，无媒体进程或 MiPlay 输出流 |
| MiPlay 实际解码输出 | 4 秒 paced 模拟音源，62 个媒体帧；真实 output.monitor 录得 3.9 秒连续 997Hz；54 次唯一路由检查；结束后 idle 且没有遗留播放进程 |
| 构建和文件检查 | 镜像构建、vendor SHA256、Compose 校验和 git diff 检查通过 |

复现/验证命令：

```sh
docker compose -f compose.test.yaml up -d --wait --wait-timeout 120
python3 tests/miplay_presence.py
docker run --rm --network none -v "$PWD:/workspace:ro" --entrypoint python3 \
  lan-audio-bridge:0.2.1 -B -m unittest discover -s /workspace/tests -p 'test_*.py' -q
```

`miplay_presence.py` 只允许本地独立 `compose.test.yaml` 的 null 输出实例，并自动清理观察者容器。40 秒观察证明跨过原 15 秒断线点；120 秒静默过期行为由缩短期限的单元测试验证。现代封装回归使用 mock 分发，不代表真实现代握手或手机互通证明。

## 交付和待手机复测

镜像标签：`lan-audio-bridge:0.2.1`。

镜像 ID：`sha256:969eb47b4e3594725a77e622ed8430694a88ee6754b867e92e5b2087c2ffff67`。

镜像归档 `lan-audio-bridge-0.2.1.tar` 大小 860445184 字节，SHA256 为 `31465c771e7be2edf6941999574dfc77a5d7814e50661ae443b529b3b83b9af5`。本机 null 演示实例已更新至 0.2.1 并 healthy；独立测试和观察者容器已清理。NAS 镜像导入和 App 更新由用户执行，本次只准备交付文件。

更新后请在手机重新打开妙播面板，保持至少一分钟，检查 NAS Audio 是否持续显示；空闲时应按 idle 显示，确认“暂无歌名”副标题是否消失。真实播放和暂停时会如实上报对应状态，不强制让手机隐藏所有媒体信息。截图中的具体 UI 效果尚未由本次软件测试直接验证。

此修复没有声称已经通过 NAS 现场日志确认所有消失原因。CoAP、旧版 5355 和 `_lyra-mdns` 的兼容范围仍与 0.2.0 相同。现有 DLNA、USB 及其他协议验证记录保留其原版本边界。
