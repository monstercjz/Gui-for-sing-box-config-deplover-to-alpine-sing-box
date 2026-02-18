#!/bin/sh

# ====================================================
# Sing-box Receiver 自动部署脚本 (Alpine Linux 专用)
# 适用场景：生产环境最佳实践部署
# ====================================================

set -e # 出错立即停止

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
done_msg() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 检查权限 ---
if [ "$(id -u)" -ne 0 ]; then
    error "必须以 root 用户运行此脚本"
fi

# --- 配置参数 (请根据需要修改) ---
INSTALL_DIR="/opt/sing-box-receiver"
CONF_DIR="/etc/sing-box/conf.d"
BACKUP_DIR="/etc/sing-box/backups"
LOG_DIR="/var/log"
SERVICE_NAME="sing-box-receiver"

# --- 1. 安装基础依赖 ---
log "正在同步仓库并安装依赖 (nodejs, npm, sing-box)..."
apk update
apk add nodejs npm openrc --no-cache

# --- 2. 创建目录结构 ---
log "配置目录结构..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONF_DIR"
mkdir -p "$BACKUP_DIR"
mkdir -p "/var/lib/sing-box" # 用于存放 cache.db

# --- 3. 部署 Node.js 环境 ---
log "安装 Node.js 依赖包..."
cd "$INSTALL_DIR"
if [ ! -f "package.json" ]; then
    npm init -y > /dev/null
fi
npm install express crypto-js --save

# --- 4. 写入服务端核心代码 (server.js) ---
log "生成 server.js..."
cat << 'EOF' > "$INSTALL_DIR/server.js"
const express = require('express');
const CryptoJS = require('crypto-js');
const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

const app = express();
// ==========================================
// 可以从guiforsingbox中获取的配置文件中分离路由，dns，outbound
// ==========================================
// ==========================================
// ⚙️ 生产环境核心配置
// ==========================================
const CONFIG = {
    PORT: 8080,
    TOKEN: "my_token_123",              
    SECRET: "my_key_456",           // 必须与发送端一致
    
    // 📁 路径配置
    // BASE_DIR: sing-box 读取配置的主目录
    BASE_DIR: "/etc/sing-box/conf.d",
    // BACKUP_DIR: 必须位于 conf.d 之外，防止 sing-box 读取到重复 Tag 导致启动失败
    BACKUP_DIR: "/etc/sing-box/backups", 
    
    PROXY_FILE: "10-proxy.json",      // 客户端推送的业务配置
    SYSTEM_FILE: "00-system.json",    // 本地系统级配置 (Log/Inbounds)
    
    MAX_BACKUPS: 3,                   // 历史备份保留份数

    // 🖥️ Alpine OpenRC 命令集
    CMD: {
        // 重启服务
        RESTART: "rc-service sing-box restart",
        // 检查状态 (返回 0 表示运行中，3 表示停止，其他为异常)
        STATUS: "rc-service sing-box status",
        // 语法校验 (显式指定二进制路径更安全)
        CHECK: "/usr/bin/sing-box check -C /etc/sing-box/conf.d"
    },
    
    // ⏱️ 执行超时设置 (毫秒)
    // 防止 execSync 因为磁盘IO或系统问题无限卡死
    EXEC_TIMEOUT: 10000, 

    // 🏥 健康检查策略 (防 CrashLoop)
    HEALTH: {
        INITIAL_DELAY: 1500, // 重启后等待 1.5s (TUN 网卡初始化需要时间)
        CHECK_COUNT: 5,      // 连续检查 5 次
        INTERVAL: 1000       // 每次间隔 1s
    }
};

// ==========================================
// 🛡️ Alpine TUN 模式最佳实践模板
// (当 00-system.json 缺失时自动生成此配置)
// ==========================================
const DEFAULT_SYSTEM_CONFIG = {
    log: {
        level: "info",
        output: "/var/log/sing-box.log",
        timestamp: true
    },
    inbounds: [
        {
            type: "tun",
            tag: "tun-in",
            interface_name: "tun0",     // 虚拟网卡名称
            address: "172.19.0.1/30",
            mtu: 9000,                  // 高性能 MTU
            auto_route: true,           // 自动接管系统路由
            strict_route: true,         // 防止 DNS 泄漏
            stack: "system",            // Linux 推荐使用 system stack，性能优于 gvisor
            sniff: true,                // 开启嗅探 (由 route 里的 domain 规则使用)
            sniff_override_destination: false
        }
    ],
    experimental: {
        cache_file: {
            enabled: true,
            path: "/var/lib/sing-box/cache.db",
            store_fakeip: true
        },
        clash_api: {
            external_controller: "0.0.0.0:9090", // 方便 Web 面板管理
            external_ui: "/usr/share/sing-box/ui"
        }
    }
};

// 全局部署锁 (单进程模式下有效)
let isDeploying = false;

// 日志工具
const log = (msg, level = 'INFO') => {
    const time = new Date().toISOString().substring(11, 19);
    console.log(`[${time}] [${level}] ${msg}`);
};

// ==========================================
// 🔧 核心工具函数
// ==========================================

/**
 * 带超时的命令执行器
 * 防止 execSync 卡死导致服务不可用
 */
const runCmd = (command) => {
    try {
        execSync(command, { stdio: 'pipe', timeout: CONFIG.EXEC_TIMEOUT });
    } catch (e) {
        // 区分是执行报错还是超时
        if (e.code === 'ETIMEDOUT') {
            throw new Error(`命令执行超时 (${CONFIG.EXEC_TIMEOUT}ms): ${command}`);
        }
        const stderr = e.stderr ? e.stderr.toString() : e.message;
        throw new Error(`命令执行失败: ${stderr}`);
    }
};

/**
 * 原子写入文件
 * 先写入临时文件，再重命名。确保文件要么完整写入，要么不存在，不会损坏。
 */
const atomicWrite = (filePath, content) => {
    const tempPath = filePath + ".tmp." + Date.now();
    try {
        fs.writeFileSync(tempPath, content);
        fs.renameSync(tempPath, filePath); // rename 是原子操作
    } catch (e) {
        // 如果失败，尝试清理临时文件
        if (fs.existsSync(tempPath)) {
            try { fs.unlinkSync(tempPath); } catch {}
        }
        throw e;
    }
};

/**
 * 确保系统基础配置文件存在
 * 如果不存在，则生成高性能 TUN 模板
 */
const ensureSystemConfig = () => {
    const sysPath = path.join(CONFIG.BASE_DIR, CONFIG.SYSTEM_FILE);
    
    // 确保基础目录存在
    if (!fs.existsSync(CONFIG.BASE_DIR)) {
        fs.mkdirSync(CONFIG.BASE_DIR, { recursive: true });
    }

    if (!fs.existsSync(sysPath)) {
        log(`[INIT] 检测到系统配置缺失，正在生成默认 TUN 模板...`, 'WARN');
        try {
            // 确保存放 cache.db 的目录存在
            const cacheDir = path.dirname(DEFAULT_SYSTEM_CONFIG.experimental.cache_file.path);
            if (!fs.existsSync(cacheDir)) {
                fs.mkdirSync(cacheDir, { recursive: true });
            }

            // 使用原子写入生成系统配置
            atomicWrite(sysPath, JSON.stringify(DEFAULT_SYSTEM_CONFIG, null, 2));
            log(`[INIT] ✅ 默认系统配置已生成至: ${sysPath}`);
        } catch (e) {
            throw new Error(`无法生成系统配置: ${e.message}`);
        }
    }
};

/**
 * 滚动备份机制
 * 将即将被覆盖的内容保存到备份目录，并清理旧备份
 */
const rotateBackups = (currentContent) => {
    if (!fs.existsSync(CONFIG.BACKUP_DIR)) {
        fs.mkdirSync(CONFIG.BACKUP_DIR, { recursive: true });
    }

    // 1. 生成带时间戳的文件名
    const timestamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14); // YYYYMMDDHHMMSS
    const backupName = `proxy_${timestamp}.json`;
    const backupPath = path.join(CONFIG.BACKUP_DIR, backupName);

    // 2. 写入备份
    fs.writeFileSync(backupPath, currentContent);
    log(`📦 已归档旧配置: ${backupName}`);

    // 3. 清理多余备份 (FIFO)
    try {
        const files = fs.readdirSync(CONFIG.BACKUP_DIR)
            .filter(f => f.startsWith('proxy_') && f.endsWith('.json'))
            .map(f => ({ 
                name: f, 
                time: fs.statSync(path.join(CONFIG.BACKUP_DIR, f)).mtime.getTime() 
            }))
            .sort((a, b) => b.time - a.time); // 新的在前

        if (files.length > CONFIG.MAX_BACKUPS) {
            const toDelete = files.slice(CONFIG.MAX_BACKUPS);
            toDelete.forEach(f => {
                fs.unlinkSync(path.join(CONFIG.BACKUP_DIR, f.name));
                log(`🗑️ 清理旧备份: ${f.name}`);
            });
        }
    } catch (e) {
        log(`备份清理失败 (非致命): ${e.message}`, 'WARN');
    }
};

/**
 * OpenRC 服务状态检查
 * 返回 true 表示运行中，false 表示停止或崩溃
 */
const checkServiceHealth = () => {
    try {
        // rc-service status 返回 0 为正常运行
        execSync(CONFIG.CMD.STATUS, { stdio: 'ignore' });
        return true;
    } catch (e) {
        return false;
    }
};

// ==========================================
// 🚀 Express 应用逻辑
// ==========================================

app.use(express.json({ limit: '10mb' }));

app.post('/deploy', async (req, res) => {
    // 1. 鉴权
    const auth = req.headers.authorization;
    if (!auth || auth !== `Bearer ${CONFIG.TOKEN}`) {
        log("非法访问尝试", 'WARN');
        return res.status(401).json({ error: "Unauthorized" });
    }

    // 2. 锁检查 (防止并发写导致错乱)
    if (isDeploying) {
        return res.status(429).json({ error: "Deployment locked, please wait" });
    }
    isDeploying = true;

    const targetPath = path.join(CONFIG.BASE_DIR, CONFIG.PROXY_FILE);
    let rollbackContent = null; // 内存中的回滚数据

    try {
        log(">>> 开始部署流程...");

        // --- STEP 0: 环境自检 ---
        ensureSystemConfig();

        // --- STEP 1: 解密与解析 ---
        const { content } = req.body;
        if (!content) throw new Error("Payload empty");

        let rawConfig;
        try {
            const bytes = CryptoJS.AES.decrypt(content, CONFIG.SECRET);
            const decrypted = bytes.toString(CryptoJS.enc.Utf8);
            if (!decrypted) throw new Error("Decryption failed / Secret mismatch");
            rawConfig = JSON.parse(decrypted);
        } catch (e) {
            throw new Error(`数据解析失败: ${e.message}`);
        }

        // --- STEP 2: 离散配置策略 (Discrete Strategy) ---
        // 核心：只提取业务配置，丢弃 log/inbounds/experimental 以保护服务端环境
        const cleanConfig = {
            dns: rawConfig.dns || {},
            outbounds: rawConfig.outbounds || [],
            route: rawConfig.route || {},
            ntp: rawConfig.ntp // 保留时间同步配置
        };
        // 移除空字段
        Object.keys(cleanConfig).forEach(k => {
            if (cleanConfig[k] === undefined || cleanConfig[k] === null) {
                delete cleanConfig[k];
            }
        });

        // --- STEP 3: 备份逻辑 ---
        if (fs.existsSync(targetPath)) {
            try {
                rollbackContent = fs.readFileSync(targetPath, 'utf8');
                // 存入磁盘归档
                rotateBackups(rollbackContent);
            } catch (e) {
                log(`⚠️ 备份归档异常: ${e.message}`, 'WARN');
            }
        }

        // --- STEP 4: 原子写入新配置 ---
        atomicWrite(targetPath, JSON.stringify(cleanConfig, null, 2));
        log("新配置已原子写入磁盘");

        // --- STEP 5: 校验与重启 ---
        log("执行语法预检...");
        runCmd(CONFIG.CMD.CHECK);
        
        log("执行服务重启...");
        runCmd(CONFIG.CMD.RESTART);

        // --- STEP 6: 持续健康监测 (CrashLoop Detection) ---
        log(`进入健康监测期 (${CONFIG.HEALTH.CHECK_COUNT}秒)...`);
        
        // 初次等待 (给 TUN 网卡一点时间)
        await new Promise(r => setTimeout(r, CONFIG.HEALTH.INITIAL_DELAY));

        for (let i = 1; i <= CONFIG.HEALTH.CHECK_COUNT; i++) {
            if (!checkServiceHealth()) {
                throw new Error(`服务在启动后第 ${i} 次轮询时发现已停止 (CrashLoop)`);
            }
            if (i < CONFIG.HEALTH.CHECK_COUNT) {
                await new Promise(r => setTimeout(r, CONFIG.HEALTH.INTERVAL));
            }
        }

        log("🎉 部署成功：服务运行稳定");
        res.json({ 
            status: "success", 
            message: "Deployed and verified successfully" 
        });

    } catch (error) {
        log(`❌ 部署中断: ${error.message}`, 'ERROR');

        // --- 🚨 紧急回滚机制 ---
        try {
            if (rollbackContent) {
                log("正在回滚至上一版本...", 'WARN');
                
                // 使用原子写入进行回滚
                atomicWrite(targetPath, rollbackContent);
                
                // 尝试重启回滚后的服务
                runCmd(CONFIG.CMD.RESTART);
                
                // 简易检查
                await new Promise(r => setTimeout(r, 2000));
                if (checkServiceHealth()) {
                    log("✅ 回滚成功，服务已恢复", 'INFO');
                } else {
                    log("💀 致命：回滚后服务仍无法启动，请人工介入", 'ERROR');
                }
            } else {
                // 如果是首次部署失败，清理垃圾文件
                if (fs.existsSync(targetPath) && !rollbackContent) {
                    try { fs.unlinkSync(targetPath); } catch {}
                    log("清理无效的首次部署文件", 'WARN');
                }
            }
        } catch (rbErr) {
            log(`回滚过程异常: ${rbErr.message}`, 'ERROR');
        }

        res.status(500).json({ status: "error", message: error.message });
    } finally {
        isDeploying = false;
    }
});

// 简单存活检测
app.get('/health', (req, res) => {
    checkServiceHealth() ? res.json({status: "UP"}) : res.status(503).json({status: "DOWN"});
});

// 初始化：启动时确保环境正常
ensureSystemConfig();

app.listen(CONFIG.PORT, '0.0.0.0', () => {
    log(`============================================`);
    log(`🚀 Alpine Sing-box 强力接收器已启动`);
    log(`📡 端口: ${CONFIG.PORT}`);
    log(`📂 配置目录: ${CONFIG.BASE_DIR}`);
    log(`📦 备份目录: ${CONFIG.BACKUP_DIR}`);
    log(`🛡️ 保护模式: Log/Inbounds/Experimental 被锁定`);
    log(`============================================`);
});
EOF

# --- 5. 生成 OpenRC 服务脚本 ---
log "配置 OpenRC 服务守护进程..."
cat << EOF > "/etc/init.d/$SERVICE_NAME"
#!/sbin/openrc-run

name="sing-box-receiver"
description="Sing-box Receiver Service"

# 1. 务必修改为你实际存放 server.js 的目录
directory="/root/sing-box-receiver"

# 2. 务必确保这里是 `which node` 查出来的路径
command="/usr/bin/node"
command_args="server.js"

# 3. 指定运行用户
command_user="root"

# 4. 使用 supervise-daemon 守护进程（防崩溃 + 后台运行）
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0

# 5. 日志路径
output_log="/var/log/sing-box-receiver.log"
error_log="/var/log/sing-box-receiver.err.log"
# --- 添加以下两行解决中文乱码 ---
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
# 6. 【关键修正】强制设置环境变量，防止找不到 node_modules
export NODE_ENV=production
export PATH=$PATH:/usr/bin:/usr/local/bin

depend() {
    need net
    after firewall
}

start_pre() {
    # 检查 server.js 是否存在
    if [ ! -f "$directory/$command_args" ]; then
        eerror "Error: Cannot find $command_args in $directory"
        return 1
    fi

    # 确保日志文件存在且有权限
    checkpath -f -m 0644 -o "$command_user" "$output_log"
    checkpath -f -m 0644 -o "$command_user" "$error_log"
}
EOF

chmod +x "/etc/init.d/$SERVICE_NAME"

# --- 6. 启动服务 ---
log "启动并启用服务..."
rc-update add "$SERVICE_NAME" default
rc-service "$SERVICE_NAME" restart

# --- 7. 最终检查 ---
sleep 2
if rc-service "$SERVICE_NAME" status | grep -q "started"; then
    done_msg "部署圆满完成！"
    echo -e "------------------------------------------------"
    echo -e "服务状态: RUNNING"
    echo -e "监听端口: 8080"
    echo -e "项目路径: $INSTALL_DIR"
    echo -e "配置路径: $CONF_DIR"
    echo -e "日志文件: $LOG_DIR/$SERVICE_NAME.log"
    echo -e "------------------------------------------------"
    echo -e "请记得修改 $INSTALL_DIR/server.js 中的 TOKEN 和 SECRET"
else
    error "服务启动失败，请检查日志: $LOG_DIR/$SERVICE_NAME.err.log"
fi