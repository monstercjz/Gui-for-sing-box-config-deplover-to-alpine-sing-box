/**
 * @name Alpine 远程部署助手
 * @description 配合 Alpine 工业级接收器，将当前配置安全推送至远程服务器
 * @version 1.4.0
 * @author 用户定制
 */

// ==========================================
// ⚙️ 预定义配置 (如果没有在界面设置，则使用这里的值)
// ==========================================
const DEFAULT_CONFIG = {
  address: 'http://192.168.3.103:8080', // 你的服务器地址
  token: 'my_token_123',           // 对应服务端的 TOKEN
  secret: 'my_key_456'             // 对应服务端的 SECRET
}

const PATH = 'data/third/alpine-deployer'
const JS_FILE = PATH + '/crypto-js.js'

/**
 * 核心：执行部署逻辑
 * @param {Object} profile - 选中的配置对象
 */
const Deploy = async (profile) => {
  // 1. 强效加载并检查加密库
  await loadDependence()
  if (!window.CryptoJS) throw '加密库 CryptoJS 加载失败，请先点击“安装”按钮'

  // 2. 读取插件属性设置
   // 获取参数：优先取界面设置 (Plugin.xxx)，若无则取预定义值 (DEFAULT_CONFIG.xxx)
  const address = Plugin.ServerAddress || DEFAULT_CONFIG.address
  const token = Plugin.Token || DEFAULT_CONFIG.token
  const secret = Plugin.Secret || DEFAULT_CONFIG.secret

  if (!address || !token || !secret) {
    throw '请先在插件设置中配置：服务器地址、Token 和加密密钥'
  }

  // 处理 URL 尾部斜杠，防止拼接错误
  const cleanAddr = address.replace(/\/+$/, '')
  const targetUrl = cleanAddr.startsWith('http') ? `${cleanAddr}/deploy` : `http://${cleanAddr}/deploy`

  const { success, error, update, destroy } = Plugins.message.info(`正在部署: ${profile.name}`, 60000)

  try {
    // 3. 生成 Windows 原始完整配置
    // 遵循“所见即所得”，不再对生成的 config 做任何修改
    update('正在生成原始配置...')
    let config = await Plugins.generateConfig(profile)

    // 4. 加密完整配置
    // 我们发送整个 config，由 Alpine 端的 server.js 负责提取 dns/outbounds/route 并丢弃本地垃圾信息
    update('正在进行 AES 加密...')
    const content = JSON.stringify(config)
    
    // 使用默认的 AES 加密 (OpenSSL KDF兼容模式)
    const encrypted = window.CryptoJS.AES.encrypt(content, secret).toString()

    // 5. 推送到 Alpine
    update('正在推送至服务器并等待预检...')
    
    const { status, body } = await Plugins.HttpPost(
      targetUrl,
      {
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json'
      },
      { content: encrypted }
    )

    // 6. 处理服务器返回的结果
    let result = typeof body === 'string' ? JSON.parse(body) : body

    if (status !== 200) {
      throw result.message || '服务器拒绝了请求'
    }

    success(`[${profile.name}] 部署并预检通过！`)
  } catch (err) {
    console.error('[Alpine Deployer]', err)
    error('部署失败: ' + err)
  } finally {
    await Plugins.sleep(2000).then(() => destroy())
  }
}

/**
 * 触发器 1：右键菜单 (由 UI 里的 "上下文-配置" 绑定)
 */
const onContextDeploy = async (profile) => {
  if (!profile) return
  await Deploy(profile)
}

/**
 * 触发器 2：插件界面“运行”按钮
 */
const onRun = async () => {
  const profileStore = Plugins.useProfilesStore()
  let profile = await profileStore.active

  // 如果当前没激活配置，弹窗让用户选一个
  if (!profile) {
    const allProfiles = profileStore.profiles
    if (!allProfiles || allProfiles.length === 0) throw '未找到任何配置'

    const selectedId = await Plugins.picker.single(
      '请选择要部署到 Alpine 的配置',
      allProfiles.map(p => ({ label: p.name, value: p.id })),
      []
    )
    if (!selectedId) return
    profile = allProfiles.find(p => p.id === selectedId)
  }

  await Deploy(profile)
}

// /**
//  * 生命周期：安装 (下载依赖)
//  */
// const onInstall = async () => {
//   await Plugins.Download('https://unpkg.com/crypto-js@latest/crypto-js.js', JS_FILE)
//   return 0
// }
/**
 * 如果你保留了 Metadata 里的安装按钮，它也可以调用这个逻辑
 */
const onInstall = async () => {
  await loadDependence()
  return 0
}

/**
 * 生命周期：卸载 (清理文件)
 */
const onUninstall = async () => {
  await Plugins.RemoveFile(PATH)
  return 0
}

/**
 * 生命周期：准备就绪
 */
const onReady = async () => {
  await loadDependence()
}

/**
 * 内部函数：动态加载 CryptoJS
 * 增加了 script.onload 处理，比单纯 sleep 更稳定
 */
async function loadDependence() {
  if (window.CryptoJS) return // 1. 内存有，直接过

  try {
    // 2. 尝试读取。注意：这里加了 .catch(() => null)，防止文件不存在时直接跳到最外层错误
    let text = await Plugins.ReadFile(JS_FILE).catch(() => null)

    // 3. 【核心进化】：如果读不到，不报错，而是原地直接下载
    if (!text) {
      console.log('检测到缺少依赖，正在自动获取...')
      await Plugins.Download('https://unpkg.com/crypto-js@latest/crypto-js.js', JS_FILE)
      text = await Plugins.ReadFile(JS_FILE) // 下载完立马读出来
    }

    // 4. 注入脚本
    await new Promise((resolve, reject) => {
      const script = document.createElement('script')
      script.id = 'crypto-js-lib'
      script.textContent = text // 直接注入文本，这是同步的
      document.body.appendChild(script)
      
      // 5. 【稳定性进化】：与其等待 onload (注入 textContent 有时不会触发 onload)，
      // 不如直接轮询检查 window.CryptoJS 是否出现
      let counter = 0
      const check = setInterval(() => {
        if (window.CryptoJS) {
          clearInterval(check)
          resolve()
        } else if (counter > 20) {
          clearInterval(check)
          reject('脚本解析超时')
        }
        counter++
      }, 100)
    })
  } catch (e) {
    throw `组件自检失败: ${e}`
  }
}