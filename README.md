# Sing-box 多协议一键部署脚本

一个强大的 Sing-box 自动化部署工具，支持SS/HY2/TUIC/VLESS Reality/AnyTLS Reality 协议自选部署和线路机 VLESS Reality 中转的完整解决方案。

---

## ✨ 主要特性

### 🎯 部署机功能

- ✅ **一键安装** - 自动部署 Sing-box 最新服务端
- ✅ **自动生成** - 自动生成 密钥和配置文件，Reality 自选或默认SNI
- ✅ **Reality SNI 优选** - 参考 3x-ui 的 TLS 1.3、h2、X25519、证书校验规则，对每个候选连续检测 3 次并按成功率和中位延迟排序
- ✅ **RealiTLScanner 集成** - 支持导入扫描器 CSV，或调用服务器上已安装的 RealiTLScanner，再进行严格复检
- ✅ **多系统支持** - 支持 Alpine, Debian, Ubuntu, CentOS, RHEL, Fedora 等操作系统
- ✅ **开机自启** - 自动配置 Systemd / OpenRC 开机自启，崩溃自动拉起服务端
- ✅ **连接 IP** - 自动获取公网 IP 或手动输入 连接IP/DDNS域名 并生成客户端链接
- ✅ **管理工具** - 输入 sb 指令进入管理界面查看节点链接、重置端口、服务端控制查看等功能
- ✅ **安装后新建节点** - 在 `sb` 中为当前配置补建尚未部署的 SS、HY2、TUIC、VLESS Reality 或 AnyTLS Reality 节点
- ✅ **运行后重选 SNI** - 可在 `sb` 管理菜单中重新优选并同步更新 Reality 配置、缓存和客户端链接
- ✅ **多客户端管理** - 为 VLESS Reality 查看、新增、批量生成、删除或重置独立 UUID，并为每个客户端生成单独链接
- ✅ **BBR 管理** - 在 `sb` 中查看内核、拥塞控制和队列规则状态，并安全启用和持久化 BBR

### Reality SNI 优选说明

选择 VLESS Reality 或 AnyTLS Reality 后，安装脚本会提供以下方式：

1. 快速优选常用目标。
2. 导入 RealiTLScanner 的 `out.csv`。
3. 调用已经安装在服务器上的 `RealiTLScanner` 或 `realitlscanner`。
4. 严格验证手动输入的域名。
5. 使用默认 `addons.mozilla.org`。
6. 直接手动设置，不进行检测。

严格检测要求目标同时满足 TLS 1.3、HTTP/2 `h2`、X25519 和可信且匹配的证书。每个目标检测 3 次，至少成功 2 次才会进入可选列表，延迟使用成功检测的中位数。

RealiTLScanner 上游建议优先在本地运行。大范围 IP/CIDR 扫描可能触发云服务商风控，因此脚本不会默认扫描；调用服务器上的扫描器前会再次要求确认。CSV 导入最多取前 50 个去重后的非通配符域名进行复检。

Reality 扫描临时文件使用独立随机目录创建，兼容 GNU coreutils、BusyBox/Toybox 等不同 `mktemp` 实现。输入连接 IP 或 DDNS 域名只影响客户端连接地址，不会被当作 Reality SNI。

### Reality 客户端管理

安装完成后运行 `sb`，选择“Reality 客户端管理”。每个 VLESS Reality 客户端拥有独立名称和 UUID，共用当前入站的端口、Reality 公钥、Short ID 和 SNI。支持一次批量创建 1-20 个客户端；删除时至少保留一个客户端。所有增删改操作都会先通过 `sing-box check`，成功后才替换配置、重启服务并重新生成 `/etc/sing-box/uris.txt`。

### 安装后新建节点

运行 `sb` 后选择“新建节点”，可以为安装时没有选择的协议补建一个节点。脚本会检查端口冲突，为 HY2/TUIC 复用或生成证书，为 Reality 协议复用现有密钥和 SNI（首次创建时进入 SNI 优选），并在 `sing-box check` 通过后才更新配置和重启服务。当前每种协议保持一个入站；VLESS Reality 的多设备或多用户通过“Reality 客户端管理”新增独立 UUID。

### BBR 管理

运行 `sb` 后选择“BBR 管理”，可以查看当前内核版本、可用拥塞控制算法、当前算法、默认队列规则和 `tcp_bbr` 模块状态。启用操作会先确认内核支持，再设置 `net.ipv4.tcp_congestion_control=bbr` 和 `net.core.default_qdisc=fq`，持久化到 `/etc/sysctl.d/99-singbox-bbr.conf`。如果容器或服务商内核拒绝参数，脚本会删除新配置并尽力恢复原值。BBR 主要作用于 TCP，Hysteria2 和 TUIC 等 UDP 协议不会直接受益。

### 🔗 线路机功能

- ✅ **一键生成** - 从落地机直接生成线路机安装脚本
- ✅ **Reality 入站** - 自动部署 VLESS Reality 入站
- ✅ **灵活端口** - 支持自动寻找空闲端口或手动指定
- ✅ **流量转发** - 自动转发流量到落地机SS节点
- ✅ **完整链接** - 生成可用的 VLESS Reality 客户端链接

## 🙏 特别鸣谢以下商家对本项目的赞助支持

<div align="center">

<table>
  <tr>
    <td align="center" width="220">
      <a href="https://app.kaze.network/" target="_blank">
        <img src="https://app.kaze.network/templates/lagom2/assets/img/logo/logo_big.634794647.svg" width="100" alt="Kaze" />
        <br><sub><b>Kaze</b></sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://console.alice.sh/" target="_blank">
        <img src="https://console.alice.sh/assets/images/logo-yellow.svg" width="100" alt="AliceNetworks" />
        <br><sub><b>AliceNetworks</b></sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://lxc.lazycat.wiki" target="_blank">
        <img src="https://lxc.lazycat.wiki/upload/logo2.png" width="100" alt="懒猫云" />
        <br><sub><b>懒猫云</b></sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://www.lxc.wiki/" target="_blank">
        <img src="https://www.lxc.wiki/themes/web/starvm-phj/img/logo.png" width="100" alt="拼好鸡" />
        <br><sub><b>拼好鸡</b></sub>
      </a>
    </td>

  </tr>
</table>

</div>

## ✅ 一键部署命令

安装全功能 sing-box：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gzjacktang/singbox-deploy/main/install-singbox-yyds.sh)"
