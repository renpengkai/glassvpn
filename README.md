# GlassVPN

轻量的 macOS 代理客户端。原生 SwiftUI 编写，适配 macOS 26/27 液态玻璃；功能参考 [KaringX/karing](https://github.com/KaringX/karing)，内核使用 [sing-box](https://github.com/SagerNet/sing-box)。

- **体积小**：应用本身约 2～3 MB，只包含界面和一个特权小工具；sing-box 内核（约 15 MB）首次使用时从官方 GitHub Releases 下载，也可以导入本地文件。
- **订阅兼容**：Clash / Clash.Meta(mihomo) YAML、V2ray / V2fly / Xray JSON、sing-box JSON、Shadowsocks SIP008、Base64 订阅、分享链接列表，以及 GitHub 上的配置文件（文件页、raw、Gist、私有仓库令牌、加速镜像）。
- **协议**：Shadowsocks（含 obfs / v2ray-plugin）、VMess、VLESS（含 Reality / Vision）、Trojan、Hysteria、Hysteria2（含端口跳跃）、TUIC、SOCKS5、HTTP、AnyTLS；传输层支持 WebSocket、gRPC、HTTP/2、HTTPUpgrade、QUIC。
- **接管方式**：系统代理（HTTP/HTTPS/SOCKS5 混合端口），或 TUN 模式接管所有应用流量。
- **界面**：菜单栏弹窗（一键连接、模式、节点切换）+ 主窗口（概览、节点、订阅、日志、设置）。

## 构建

需要 Xcode 26 及以上（液态玻璃 API 来自 macOS 26 SDK；用旧版 Xcode 也能编译，只是没有玻璃效果）。

```bash
./scripts/package-app.sh          # 生成 dist/GlassVPN.app 与 zip
ARCH=x86_64 ./scripts/package-app.sh
```

推送到 GitHub 后，`.github/workflows/build-macos.yml` 会自动构建；推送 `v*` 标签会发布 Release。

## 使用

1. 首次打开会显示主窗口，在「设置 → sing-box 内核」点击下载（访问 GitHub 慢时可先填写 GitHub 加速镜像）。
2. 在「订阅」中添加订阅链接、GitHub 文件地址，或粘贴分享链接 / 配置内容。
3. 点击连接按钮。默认是规则模式：国内域名与 IP 直连，其余走代理。
4. 需要 TUN 模式时，在「设置 → 特权组件」安装一次（会请求管理员密码），然后打开 TUN 开关。

## 实现说明

| 目录 | 内容 |
| --- | --- |
| `Sources/GlassVPN/Parsing` | 各订阅格式解析，统一转换成 sing-box outbound；内置一个只覆盖 Clash 所需子集的 YAML 解析器，避免引入第三方库 |
| `Sources/GlassVPN/Core` | 订阅拉取、sing-box 配置生成（1.12+ 格式）、Clash API 客户端、内核下载、系统代理、特权组件 |
| `Sources/GlassVPN/Store` | 订阅存储与连接生命周期 |
| `Sources/GlassVPN/Views` | SwiftUI 界面与液态玻璃适配 |
| `Sources/gvpnhelper` | setuid root 小工具：以 root 启停 TUN 内核、在普通权限不足时设置系统代理 |

运行数据位于 `~/Library/Application Support/GlassVPN`（订阅、内核、生成的配置、日志）。TUN 模式的内核以 root 运行，日志在 `/Library/Logs/GlassVPN/core.log`。

sing-box 不支持的协议（SSR、Snell、xhttp、KCP 等）在导入时会被跳过；WireGuard 在 sing-box 中属于 endpoint，当前未导入。

## 安全提示

特权组件是 setuid root 程序，本机任何进程都可以调用它来启停代理内核、修改系统代理。它只接受固定的几个命令，并且只运行安装时复制到 root 目录的那份内核；如果不需要 TUN，可以不安装，或在设置中卸载。
