# 0.2.2 音量同步与空闲输出验证（2026-11-01）

## 变更

- MiPlay 使用接收器共享音量，播放连接、既有探测连接和新连接读取相同数值。已认证控制连接可直接调音；重新连接或 OPEN 不再恢复连接创建时的初值。
- 合法音量请求在发送 ACK 前更新共享目标，OPEN 在异步生命周期回调后读取最新值，避免并发连接回写旧音量。重复同值请求仍下发，0 表示静音；配置上限与初始音量独立。
- 公共输出 `OUTPUT_VOLUME` 默认从 70 改为 100，即 [PulseAudio 定义的 0 dB](https://www.freedesktop.org/software/pulseaudio/doxygen/volume_8h.html)。显式旧配置继续生效，升级时需同步修改才能取消公共输出衰减。
- 启动空闲、停止或全部输入暂停时，输出静音、卸载路由并挂起；播放时依次静音、恢复、创建路由和取消静音。先恢复输出可避免在挂起目标上初始化 loopback；相关行为见 [PulseAudio 17 源码](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/modules/module-loopback.c)。

## 本机软件验证

测试使用本机 Docker 的独立 bridge/null 输出实例，不包含生产部署或物理音频设备操作。

| 检查 | 结果 |
| --- | --- |
| 修复前复现 | 一条连接 SET 35 后自身 GET 为 35，既有及新探测连接仍返回 100，未 OPEN 的控制连接没有下发音频总线音量 |
| 单元与协议回归 | 109 项全部通过，无依赖跳过；覆盖共享状态、并发 ACK/OPEN、静音、上限、非法输入、合并下发及挂起/恢复失败路径 |
| 真实控制连接与 Pulse 总线 | 三条持久连接连续 20 秒、20 组查询及 7 次新建连接，音量保持 35；0、42、100 的状态回报与 `miplay_bus` 实际数值一致 |
| 控制探测与空闲 | 控制测试未创建 PCM 流或路由，公共输出音量不变且始终为 `SUSPENDED` |
| 输出幅度 | 相同合成音实录：100% 幅度 10000.95，70% 幅度 3428.96，比例 2.917；恢复 100% 后幅度回到原水平 |
| 音源切换 | 12 个有向跨协议切换通过，真实录音保持唯一音源；停止后输出挂起，无旧源回退 |
| DLNA | 真实 SOAP Play/Pause/Seek/Play/Stop 通过；暂停、停止时挂起，恢复后实际录音正常 |
| MiPlay 音频 | 62 个媒体帧，实际输出包含 4.0 秒连续 997 Hz 音频，52 次唯一路由检查；结束后挂起且无遗留播放进程 |
| 启动与恢复 | Pulse 运行身份、私有总线、模块加载通过；四个接收器异常恢复、Pulse 核心退出、持久身份及 SIGTERM 重启检查通过 |
| 构建 | vendor 文件哈希、镜像构建、Compose 与文档检查通过 |

MiPlay 完整加密手机互通仍需目标客户端验收；封装单元测试仅使用模拟分发。共享音量是异步下发的目标值，实际 Pulse 命令失败时保留最后成功应用值，重复请求可重试。当前音量在接收器进程内保存，进程重启后使用初始值。

空闲挂起在 null 输出上验证，不代表已测量物理设备接口、电平或载波状态。ALSA 挂起用于停止音频数据输出并释放设备，外接硬件的载波与待机行为须单独验证。

## 复现

```sh
docker build -t lan-audio-bridge:0.2.2 .
docker compose -f compose.test.yaml up -d --wait --wait-timeout 120
docker run --rm --network none -v "$PWD:/workspace:ro" --entrypoint python3 \
  lan-audio-bridge:0.2.2 -B -m unittest discover -s /workspace/tests -p 'test_*.py' -q
python3 tests/integration.py

cid=$(docker compose -f compose.test.yaml ps -q audio)
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")
docker exec -i "$cid" python3 - --target "$ip" --source-address "$ip" < tests/miplay_volume.py
docker exec -i "$cid" python3 - --target "$ip" --source-address "$ip" --duration 4 < tests/miplay_sender.py
docker compose -f compose.test.yaml down
```

## 构建记录

- 镜像标签：`lan-audio-bridge:0.2.2`。
- 镜像 ID：`sha256:e428763f4689c133dcfecffd76b9be40b1f530bb1e25d864e7f4a7d714913650`。
- 本地镜像归档大小：860468224 字节。
- 归档 SHA256：`ecd4e9a781fe94214730c7f81f02549b27ea4ee577c385742aab005213ea3507`。

归档与原始输出位于忽略目录，不包含在源码仓库中。上述记录不代表 NAS 应用已升级或手机已完成复测。
