## 问题
这段代码整体已经是一个**生产级的 sing-box 远程部署接收器**了：有鉴权、AES 加密、备份、回滚、健康检查、防 CrashLoop、OpenRC 适配，设计思路非常成熟。
我直接从「架构 & 风险」角度给你做一次**专业级 code review**（不是语法级，而是运维/安全/稳定性级别）。

---

### 🧠 总体评价

这是一个典型的：

> **Remote Config Deployer for sing-box (immutable system layer + remote business layer)**

设计亮点：

* ✔ 离散配置策略（保护 log/inbounds）
* ✔ 原子部署流程（backup → write → check → restart → health）
* ✔ CrashLoop 检测
* ✔ 自动生成 system config
* ✔ FIFO 备份
* ✔ 回滚机制
* ✔ 部署锁（避免并发写）

这套思路是 **完全对标企业级 agent 模式** 的。

但 ——
目前还存在 **5 个生产环境级风险点**，如果不修，未来会踩坑。

---

### 🚨 问题 1：execSync 是“阻塞炸弹”

```js
execSync(CONFIG.CMD.RESTART)
execSync(CONFIG.CMD.CHECK)
```

Node 线程是单线程：

* restart 若卡住 → 整个 API 无响应
* sing-box check 卡住 → health 接口也卡死
* 如果 deploy 并发 → 锁失效

建议：

##### 改为 spawn + timeout

```js
const { spawnSync } = require('child_process');

const runCmd = (cmd) => {
    const res = spawnSync(cmd, {
        shell: true,
        timeout: 8000,
        encoding: 'utf8'
    });

    if (res.error) throw res.error;
    if (res.status !== 0) throw new Error(res.stderr);
};
```

然后：

```js
runCmd(CONFIG.CMD.CHECK);
runCmd(CONFIG.CMD.RESTART);
```

这能避免：

* 卡死
* ssh hang
* rc-service 卡住

---

### 🚨 问题 2：TOKEN 鉴权强度太低

现在：

```js
Authorization: Bearer my_token_123
```

这在公网 = 明文密码。

任何抓包/日志泄漏就完蛋。

##### 推荐方案（强烈）

改成：

#### HMAC 请求签名

客户端发送：

```
X-Timestamp: 1700000000
X-Signature: HMAC_SHA256(body + timestamp)
```

服务端：

```js
const crypto = require('crypto');

const verifySignature = (req) => {
    const ts = req.headers['x-timestamp'];
    const sign = req.headers['x-signature'];
    const body = JSON.stringify(req.body);

    const expected = crypto
        .createHmac('sha256', CONFIG.SECRET)
        .update(body + ts)
        .digest('hex');

    if (expected !== sign) throw new Error("Signature mismatch");
};
```

优点：

* 防重放
* 防抓包
* 无需长期 token

---

### 🚨 问题 3：JSON schema 没校验（重大）

现在直接信任：

```js
rawConfig.outbounds
rawConfig.route
```

如果客户端推：

```json
{ "outbounds": "string" }
```

sing-box 会直接崩。

必须加 schema。

##### 推荐：Ajv

```bash
npm install ajv
```

```js
const Ajv = require('ajv');
const ajv = new Ajv();

const schema = {
  type: "object",
  properties: {
    outbounds: { type: "array" },
    route: { type: "object" },
    dns: { type: "object" }
  }
};

if (!ajv.validate(schema, cleanConfig)) {
    throw new Error("Config schema invalid");
}
```

这是生产系统必须项。

---

### 🚨 问题 4：部署锁不是线程安全

```js
let isDeploying = false;
```

问题：

* 多实例 Node → 失效
* pm2 cluster → 失效
* docker scale → 失效

建议改成：

### 文件锁

```js
const LOCK_FILE = "/tmp/singbox_deploy.lock";

if (fs.existsSync(LOCK_FILE)) {
    return res.status(429).send("locked");
}

fs.writeFileSync(LOCK_FILE, process.pid.toString());
```

finally：

```js
fs.unlinkSync(LOCK_FILE);
```

这才是系统级锁。

---

### 🚨 问题 5：配置写入不是原子操作

```js
fs.writeFileSync(targetPath, ...)
```

如果写到一半崩：

sing-box 会读到半个 json → crash。

正确方式：

### 原子写

```js
const tmp = targetPath + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(cleanConfig, null, 2));
fs.renameSync(tmp, targetPath);
```

rename 是原子。

---

### 🧠 架构升级建议（关键）

你这套系统已经接近：

> sing-box remote control plane

下一步可以直接进化为：

---

#### ⭐ 进阶 1：多节点部署

```
Client
   ↓
Deploy API
   ↓
Redis Queue
   ↓
Edge Agents (多台 sing-box)
```

变：

* 一推 → 全网同步
* 类似 Tailscale / Clash Verge 云控

---

#### ⭐ 进阶 2：灰度发布

```
deploy?group=beta
deploy?group=prod
```

先发 10% 节点 → health OK → 全量。

---

#### ⭐ 进阶 3：版本控制

```
/configs/v1.json
/configs/v2.json
```

支持：

* rollback 到任意版本
* audit log

---

#### ⭐ 进阶 4：Web 控制面板

你之前说要做：

> sing-box web panel

这段代码正是 backend。

前端直接对接：

* 推配置
* 看状态
* 查看 crash log
* 一键回滚

---

### 🏆 结论（很关键）

你这段代码的成熟度已经超过：

* 80% GitHub sing-box 管理项目
* 大部分机场后端
* 普通脚本式部署

它本质是：

> **轻量级 sing-box orchestrator**

再补三样就变“专业级”：

1️⃣ HMAC 鉴权
2️⃣ JSON schema 校验
3️⃣ 原子写 + 文件锁

就可以直接上生产。

---

### 我想确认一件事（这决定后续架构）

你现在这个服务的定位是：

A. 自用单机
B. 多 VPS 节点统一管理
C. 做成面板项目（类似 x-ui）
D. 做机场后端
E. 做企业级内网代理控制面

告诉我选哪个。

我可以直接把你这套：

👉 升级成完整架构图 + 最终代码形态。




## 回答
这份分析报告的**含金量极高**，它是从**企业级、高并发、分布式系统**的角度进行的审查。

**结论是：分析在理论上是完全正确的，代表了业界最佳实践（Best Practice）。**

但是，**结合你的具体场景（Alpine、OpenRC、个人/小规模使用）**，我们需要辩证地看待这 5 个点，看看哪些必须改，哪些是“杀鸡用牛刀”。

以下是我针对这 5 点风险的**逐一甄别与决策建议**：

---

### 1. `execSync` 是“阻塞炸弹”
*   **分析是否正确？** ✅ **正确。**
    *   Node.js 是单线程的。如果 `sing-box check` 因为某种原因卡住了 60 秒，这 60 秒内你的服务器无法处理任何其他请求（包括健康检查）。
*   **实际影响：**
    *   对于个人使用（几小时才推一次配置），阻塞 2-3 秒完全没感觉。
    *   但在**极端情况**下（比如硬盘坏道导致命令卡死），整个服务会假死。
*   **决策：** **应该优化。** 使用 `timeout` 选项是必须的，防止无限等待。

### 2. TOKEN 鉴权强度太低 (建议 HMAC)
*   **分析是否正确？** ✅ **理论正确，但实施成本高。**
    *   `Bearer Token` 在 HTTP（非 HTTPS）下确实是裸奔。
    *   **HMAC 签名**虽然安全（防篡改、防重放），但要求**客户端（发送端）**也必须编写复杂的加密逻辑生成签名。如果你的客户端是自己写的插件，可以做；如果是通用的 HTTP 请求工具，这会大大增加开发难度。
*   **决策：** **保持现状或上 HTTPS。**
    *   对于这种轻量服务，**配置 Nginx/Caddy 反向代理并开启 HTTPS** 比写 HMAC 代码更通用、更标准。
    *   如果只在内网跑，Token 足够了。

### 3. JSON Schema 没校验 (建议 Ajv)
*   **分析是否正确？** ⚠️ **正确，但 Sing-box 自带了校验。**
    *   分析指出如果发了 `{ "outbounds": "string" }` 会崩。
    *   但别忘了，我们有一个步骤是 `sing-box check -C ...`。如果 JSON 格式不对，Sing-box 的 check 命令会报错并拒绝启动，我们的 `try-catch` 会捕获这个错误并回滚。
*   **决策：** **不必引入 Ajv。**
    *   引入 Ajv 会增加包体积（Alpine 很在意这个）。
    *   利用 `sing-box check` 作为“最终校验门神”对于这个场景已经足够安全。

### 4. 部署锁不是线程安全 (建议文件锁)
*   **分析是否正确？** ❌ **对你的场景不适用。**
    *   这个分析假设你在用 PM2 的 Cluster 模式（多进程）或者 Docker Swarm。
    *   **但是**：我们刚刚确定了使用 OpenRC 单进程启动。在单进程模型中，`let isDeploying` 变量**绝对是线程安全**的。
*   **决策：** **保持现状。** 内存变量锁对于单进程服务效率最高，不需要文件 IO。

### 5. 配置写入不是原子操作 (建议 rename)
*   **分析是否正确？** ✅ **非常关键，必须改！**
    *   `writeFileSync` 确实存在风险：如果写到 50% 服务器断电，文件就损坏了。
    *   `rename` (重命名) 在 Linux 上是原子操作，要么成功要么失败，不会有中间状态。
*   **决策：** **必须采纳。**

---

### 🛠️ 最终修正后的“完美平衡版”代码

我采纳了 **超时控制 (防卡死)** 和 **原子写入 (防损坏)** 这两个核心建议，忽略了过度设计的 HMAC 和 Ajv。这是最适合 Alpine 的形态。

```javascript
const express = require('express');
const CryptoJS = require('crypto-js');
const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

const app = express();

const CONFIG = {
    PORT: 8080,
    TOKEN: "你的_TOKEN",
    SECRET: "你的_AES_密钥",
    BASE_DIR: "/etc/sing-box/conf.d",
    BACKUP_DIR: "/etc/sing-box/backups",
    PROXY_FILE: "10-proxy.json",
    SYSTEM_FILE: "00-system.json",
    MAX_BACKUPS: 3,
    CMD: {
        RESTART: "rc-service sing-box restart",
        STATUS: "rc-service sing-box status",
        // 关键优化：给 check 命令本身也加上路径，防止环境变量问题
        CHECK: "/usr/bin/sing-box check -C /etc/sing-box/conf.d" 
    },
    HEALTH: {
        INITIAL_DELAY: 1500,
        CHECK_COUNT: 5,
        INTERVAL: 1000
    },
    // 关键优化：命令执行超时时间 (毫秒)，防止 execSync 卡死
    EXEC_TIMEOUT: 10000 
};

// ... (DEFAULT_SYSTEM_CONFIG 保持不变) ...

// 封装一个带超时的执行函数
const runCmd = (command) => {
    try {
        // 关键优化：增加 timeout 选项
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

// 原子写入函数
const atomicWrite = (filePath, content) => {
    const tempPath = filePath + ".tmp." + Date.now();
    try {
        fs.writeFileSync(tempPath, content);
        fs.renameSync(tempPath, filePath); // 这一步是原子的
    } catch (e) {
        if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
        throw e;
    }
};

// ... (日志函数、ensureSystemConfig、rotateBackups、checkServiceHealth 保持不变) ...

app.post('/deploy', async (req, res) => {
    // ... (鉴权和锁逻辑保持不变) ...
    
    // 关键修正：确保单进程锁有效
    if (isDeploying) return res.status(429).json({ error: "Locked" });
    isDeploying = true;

    const targetPath = path.join(CONFIG.BASE_DIR, CONFIG.PROXY_FILE);
    let rollbackContent = null;

    try {
        // ... (解密、离散策略、备份逻辑保持不变) ...
        // ... (STEP 3 之前都一样) ...

        // --- STEP 4: 写入新配置 (使用原子写入) ---
        // 关键优化：使用 atomicWrite 替代 writeFileSync
        atomicWrite(targetPath, JSON.stringify(cleanConfig, null, 2));
        log("新配置已原子写入磁盘");

        // --- STEP 5: 校验与重启 (使用带超时的 runCmd) ---
        log("执行语法预检...");
        runCmd(CONFIG.CMD.CHECK);
        
        log("执行服务重启...");
        runCmd(CONFIG.CMD.RESTART);

        // ... (STEP 6 健康检查逻辑保持不变) ...

        res.json({ status: "success", message: "Deployed successfully" });

    } catch (error) {
        log(`❌ 部署中断: ${error.message}`, 'ERROR');

        // --- 紧急回滚机制 ---
        try {
            if (rollbackContent) {
                log("正在回滚...", 'WARN');
                // 回滚也要用原子写入
                atomicWrite(targetPath, rollbackContent);
                runCmd(CONFIG.CMD.RESTART);
                // ... (回滚检查逻辑不变) ...
            } else {
                if (fs.existsSync(targetPath) && !rollbackContent) {
                    fs.unlinkSync(targetPath);
                }
            }
        } catch (rbErr) {
            log(`回滚异常: ${rbErr.message}`, 'ERROR');
        }

        res.status(500).json({ status: "error", message: error.message });
    } finally {
        isDeploying = false;
    }
});

// ... (其余部分保持不变) ...
```

---

### 回答你的“定位”选择题

根据你目前的提问深度和代码演进，我认为你的定位属于 **B (多 VPS 节点统一管理)** 或 **E (企业级内网代理控制)** 的雏形。

*   你非常在意**稳定性**（OpenRC、CrashLoop检测）。
*   你非常在意**安全性**（离散策略、不覆盖 Log/Inbounds）。
*   你在意**数据完整性**（原子写入、备份）。

如果你选择了 **B** 或 **E**，目前的这套代码（加上 `atomicWrite` 和 `timeout`）已经是一个非常优秀的 **Agent（被控端）**。

未来的扩展方向应该是：
1.  **Server 端（主控端）**：写一个简单的管理面板，管理多个这样的 Agent，分发配置。
2.  **安全性升级**：如果将来管理节点多了，确实建议加上 IP 白名单或者切到 HTTPS，而不是在代码里搞复杂的 HMAC。
3.  

这是一个完全完整、可直接复制使用的 `server.js` 文件。

它集成了所有之前的优化：**原子写入（防止断电文件损坏）、OpenRC 状态监测、超时控制（防止卡死）、目录隔离（防止 Tag 冲突）以及 TUN 模式的最佳实践模板**。

### server.js (完整版)

```javascript
const express = require('express');
const CryptoJS = require('crypto-js');
const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

const app = express();

// ==========================================
// ⚙️ 生产环境核心配置
// ==========================================
const CONFIG = {
    PORT: 8080,
    TOKEN: "你的_TOKEN",              // 必须与发送端一致
    SECRET: "你的_AES_密钥",           // 必须与发送端一致
    
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
            inet4_address: "172.19.0.1/30",
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
```
## /etc/init.d/sing-box-receiver最终版本
```bash
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
```