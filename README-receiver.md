

# Sing-box Receiver for Alpine Linux

🚀 **Sing-box Receiver** 是一个专为 Alpine Linux 设计的轻量级远程部署后端。它允许你从客户端（如 Windows 插件或 GUI 管理工具）安全地推送分流规则和节点配置，并自动完成服务重启、环境校验与健康检查。

本项目特别针对 **OpenRC** 初始化系统进行了优化，支持 **TUN 模式** 的最佳实践。

---

## ✨ 核心特性

- **🔒 安全传输**：采用 `AES-256-CBC` 对推送配置进行全程加密，并配合 `Bearer Token` 鉴权，防止配置泄露。
- **🛡️ 离散配置策略**：强制分离系统级配置（Log、Inbounds、Experimental）与业务配置（Outbounds、DNS、Route）。客户端推送无法破坏服务器的基础设施设置（如 TUN 网卡配置）。
- **🏗️ 原子化部署**：配置写入采用 `Rename` 原子操作，确保配置文件要么完整、要么不存在，彻底杜绝因断电导致的文件损坏。
- **🏥 智能健康检查**：引入 **CrashLoop 检测机制**。服务重启后会进行为期 5 秒的持续监测，若服务在启动后瞬间崩溃（如端口冲突），系统将自动执行回滚。
- **🔙 自动回滚与备份**：
    - **内存回滚**：部署失败时立即恢复至上一个运行版本。
    - **物理归档**：在 `/etc/sing-box/backups/` 中保留最近 3 份历史配置快照。
- **🛠️ 完美适配 Alpine**：使用 OpenRC `supervise-daemon` 实现进程守护，崩溃自动拉起，资源占用极低。
- **🌱 环境自愈**：首次运行若缺少 `00-system.json`，会自动生成符合 Alpine 高性能要求的 TUN 模式模板。

---

## 📋 目录结构

```text
/etc/sing-box/
├── conf.d/
│   ├── 00-system.json    # 系统级配置 (由管理员手动维护或首次启动生成)
│   └── 10-proxy.json     # 业务级配置 (由本接收器动态更新)
└── backups/              # 历史配置备份目录 (保留 3 份)

/opt/sing-box-receiver/
├── server.js             # 服务核心代码
└── node_modules/         # 依赖库
```

---

## 🚀 快速开始

### 1. 一键安装

在 Alpine Linux 终端执行以下命令：

```bash
wget -O install.sh https://your-script-url/install.sh # 或者直接运行你本地的脚本
chmod +x install.sh
./install.sh
```

### 2. 修改默认密钥

安装完成后，出于安全考虑，请务必修改配置文件中的密钥：

```bash
vi /opt/sing-box-receiver/server.js
```

修改以下字段：
```javascript
const CONFIG = {
    TOKEN: "你的自定义Token",     // 与客户端 Authorization Header 对应
    SECRET: "你的自定义AES密钥",  // 与客户端 AES 密钥对应 (32位字符串)
    // ...
};
```

修改后重启服务：
```bash
rc-service sing-box-receiver restart
```

---

## 📡 客户端推送规范

- **Endpoint**: `POST http://<server-ip>:8080/deploy`
- **Headers**:
    - `Authorization: Bearer <TOKEN>`
    - `Content-Type: application/json`
- **Payload**:
    ```json
    {
      "content": "<AES_ENCRYPTED_JSON_STRING>"
    }
    ```
- **解密后的 JSON 结构**（接收器仅提取以下字段）：
  - `dns`, `outbounds`, `route`, `ntp`

---

## 🛠️ 日常运维

### 服务管理
```bash
# 查看接收器状态
rc-service sing-box-receiver status

# 重启接收器
rc-service sing-box-receiver restart

# 查看 sing-box 本身状态
rc-service sing-box status
```

### 日志查看
```bash
# 查看标准运行日志 (部署成功/回滚提示)
tail -f /var/log/sing-box-receiver.log

# 查看错误堆栈日志 (用于排查代码错误)
tail -f /var/log/sing-box-receiver.err.log

# 查看 sing-box 系统日志
tail -f /var/log/sing-box.log
```

---

## ⚠️ 注意事项

1. **权限控制**：本程序涉及修改 `/etc/sing-box/` 目录及重启服务，默认以 `root` 用户运行。
2. **端口占用**：默认占用 `8080` 端口，请确保防火墙（awall 或 iptables）已放行。
3. **备份隔离**：请勿手动将备份文件移动到 `/etc/sing-box/conf.d/` 目录下，否则 sing-box 会因为重复 Tag 而报错。

---

## 📄 License
MIT License. 可自由修改与分发。