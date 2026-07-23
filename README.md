# Shell Scripts 集合

> 个人服务器 / 系统管理用的 shell 脚本工具集

## 📦 脚本列表

| 脚本 | 用途 | root 必需 |
|------|------|-----------|
| `outway-manager.sh` | Outway 代理服务一键安装/卸载/查看配置 | ✅ |

---

## 🚀 outway-manager.sh

**功能**: 交互式管理 [Outway](https://github.com/xiaozhou26/outway)(IPv6 代理)服务端,支持:
- 自动检测有 IPv6 全局地址的网卡
- 推导 CIDR 块(/当前段 / /56 / 自定义)
- 设置用户名密码(可随机生成)
- 可选配置 sysctl `net.ipv6.ip_nonlocal_bind=1`
- 可选配置 IPv6 路由 + 持久化到 `/etc/network/interfaces`
- 安装 outway(预编译二进制 / go install)
- 创建 systemd 服务
- 卸载: 彻底清理(服务/二进制/路由/sysctl/配置)
- 配置保存到 `/etc/outway/outway.conf`

**用法**:
```bash
sudo ./outway-manager.sh
```

**主菜单**:
```
1) 安装 Outway (交互式)
2) 卸载 Outway (彻底清理)
3) 查看当前配置
4) 退出
```

**安装后产物**:
- 二进制: `/usr/local/bin/outway`
- systemd 服务: `/etc/systemd/system/outway.service`
- 配置: `/etc/outway/outway.conf`
- (可选) 路由持久化在 `/etc/network/interfaces`

**前置依赖**:
- 操作系统: Ubuntu / Debian / CentOS / RHEL / Fedora
- IPv6 全局地址(在网卡上)
- (如选 go install) Go 1.21+ / Git
- 联网(下载 release)

---

## 📝 约定

- 所有脚本 `set -e` 早失败
- 颜色输出: RED / GREEN / YELLOW / BLUE / NC
- 配置文件在 `/etc/<script>/` 或 `/etc/<script>.conf`
- 需要 root 时显式 `check_root()`
- 危险操作(卸载/清空)有 `confirm_step()` 二次确认

## 🛡️ 安全

- 不用 `curl | bash`,所有操作透明
- 配置文件不存敏感信息到 git
- 二进制 + service 文件权限 644 / 755

## 🗑️ 卸载

```bash
sudo ./outway-manager.sh
# 选 2
# 按提示确认每一步
```

---

**作者**: Mavis + 用户共建
**最后更新**: 2026-07-23
**许可**: MIT
