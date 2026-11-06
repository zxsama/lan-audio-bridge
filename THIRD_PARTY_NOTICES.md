# 第三方组件声明

LAN Audio Bridge 的自有代码、脚本和文档采用根目录的 [MIT 许可证](LICENSE)。该授权不替代第三方组件的版权声明、许可证或分发条件。下表列出直接集成的主要组件；固定版本、构建参数和源码校验值见 [UPSTREAM.md](docs/UPSTREAM.md)。

## 仓库内的第三方源码

`app/vendor/castfabric_miplay/` 包含 CastFabric 的 MiPlay 协议模块及离线模拟器，基于提交 `5b7733ee9185a85843606de6fe94867f7d5a42cf`。

- 上游版权所有者：KiriChen-Wind、CastFabric contributors。
- 许可证：[MIT 原文](app/vendor/castfabric_miplay/LICENSE)。
- 修改说明：[NOTICE.md](app/vendor/castfabric_miplay/NOTICE.md)。
- 来源和校验值：[SOURCE.json](app/vendor/castfabric_miplay/SOURCE.json)。

本地修改不移除上游版权与许可声明；原始及修改后的文件哈希均保留在来源记录中。

## 镜像中的主要组件

| 组件 | 用途 | 许可证及声明 |
| --- | --- | --- |
| Shairport Sync | AirPlay 接收 | [MIT 及组件声明](https://github.com/mikebrady/shairport-sync/blob/0a34fbda83724cc06266aadcf7c88acc8fef4e7d/LICENSES)；源码中的部分组件采用 BSD-2-Clause、BSD-3-Clause 或 ISC-style 条款。 |
| NQPTP | AirPlay 时钟同步 | [GPL-2.0-only](https://github.com/mikebrady/nqptp/blob/ab8fb67483411640fd7f1e193889482f2421c37c/LICENSE)；版本范围由[源码声明](https://github.com/mikebrady/nqptp/blob/ab8fb67483411640fd7f1e193889482f2421c37c/nqptp.c)确定。 |
| librespot | Spotify Connect 接收 | [MIT](https://github.com/librespot-org/librespot/blob/d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d/LICENSE)；Rust 依赖适用各自许可证。 |
| gmrender-resurrect | DLNA 接收 | [GPL-2.0-or-later](https://github.com/hzeller/gmrender-resurrect/blob/v0.3/src/main.c)；Debian 包中的图标另有宽松许可声明，见安装包的 `copyright`。 |
| xdg-dbus-proxy | 宿主发现服务代理 | LGPL-2.1-or-later；兼容代码及 Debian 包装包含 LGPL-2.0-or-later 声明，见[Debian 源包](https://security.debian.org/debian-security/pool/updates/main/x/xdg-dbus-proxy/xdg-dbus-proxy_0.1.6-1+deb13u3.debian.tar.xz)的 `debian/copyright`。 |
| Debian 软件包 | PulseAudio、ALSA、Avahi、D-Bus、GStreamer、FFmpeg、Python 及依赖 | 各包适用独立许可证；以镜像内版本清单和 `/usr/share/doc/*/copyright` 为准。 |

Shairport Sync 的 `LICENSES` 包含主许可证和组件索引，并非所有组件许可证全文的合集。完整组件声明可在随镜像附带的对应源码归档中查阅，例如 `tinyhttp/LICENSE` 及相关源文件头部。

## Windows 客户端

VBAN 接收器为依据[公开 PCM 协议规范](https://vb-audio.com/Voicemeeter/VBANProtocol_Specifications.pdf)编写的项目自有代码，采用 MIT 许可证。镜像不包含 Voicemeeter 客户端、驱动或 Linux `vban` 项目的源码。

Windows 配置脚本从 [VB-Audio 官方来源](https://voicemeeter.com/)下载 Voicemeeter Standard 1.1.3.0，校验固定 SHA256 和发布者签名后调用官方安装程序及 Remote API。仓库不分发其二进制文件。Voicemeeter 采用 Donationware 授权，欢迎捐赠或购买许可证支持 VB-Audio；专业使用及分发须遵守其[授权说明](https://vb-audio.com/Services/licensing.htm)。该软件与驱动不适用本项目的 MIT 许可证。

## 测试依赖

AirPlay 发送测试在临时测试环境中安装 [pyatv 0.18.0（MIT）](https://github.com/postlund/pyatv/blob/v0.18.0/LICENSE.md)和 [srptools 1.0.1（BSD-3-Clause）](https://github.com/idlesign/srptools/blob/v1.0.1/LICENSE)。它们未由应用 Dockerfile 安装到最终运行镜像；其传递依赖同样保留各自许可。

## 声明与源码位置

按当前 Dockerfile 构建的镜像保留以下材料：

本文相对链接用于仓库浏览；镜像中的文件位置以此表为准。

| 路径 | 内容 |
| --- | --- |
| `/usr/local/share/doc/lan-audio-bridge/` | 项目 MIT 许可证、本声明、上游来源文档、Dockerfile 和 Debian 包版本清单。 |
| `/usr/local/share/doc/lan-audio-bridge/upstream/` | 直接编译组件的上游许可文件。 |
| `/usr/local/share/lan-audio-bridge/sources/` | Shairport Sync、NQPTP、librespot 的固定版本源码归档。 |
| `/app/vendor/castfabric_miplay/` | MiPlay 模块源码、MIT 许可证、修改记录和校验值。 |
| `/usr/share/doc/*/copyright`、`/usr/share/common-licenses/` | Debian 软件包版权声明及通用许可证文本。 |

分发源码时应保留适用的版权、许可和修改声明。分发镜像时，应按其中各组件的许可证提供所需声明、对应源码及构建材料；根 MIT 许可证不将整个镜像统一授权为 MIT。已有三个应用源码归档不构成整个镜像的完整对应源码包，仍需按实际构建核对 Debian 软件包、Rust 依赖及其他组件，具体方法见 [UPSTREAM.md](docs/UPSTREAM.md#notices-and-source-availability)。

AirPlay、Spotify、MiPlay 等名称仅用于说明协议或服务兼容性，不代表官方认证或隶属关系。第三方服务的账号和使用要求由相应服务提供方规定。
