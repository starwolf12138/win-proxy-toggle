# WinProxyToggle 设计说明（中文）

本文解释代码为什么这样写。英文 README 在 [`../README.en.md`](../README.en.md)，中文使用说明在 [`../README.md`](../README.md)。

## 1. 目标

做一个**小、可回退、可验证**的 Windows 代理切换工具：

- 一条命令关闭系统代理
- 一条命令恢复之前的状态
- 有托盘入口
- 不需要安装服务
- 出错时能看懂发生了什么
- 测试不会碰真实代理

## 2. 非目标

这个项目刻意不做：

- VPN
- 流量转发
- 绕过公司/学校网络策略
- 修改浏览器插件代理
- 修改正在运行进程的环境变量
- 机器级代理的默认修改

范围小是设计的一部分，不是偷懒。

## 3. 三层代理

Windows 里至少有三层容易混淆的代理：

```text
WinINET  ── HKCU\...\Internet Settings
            手动代理 / PAC
            很多桌面程序、Edge/IE 使用

WinHTTP  ── netsh winhttp
            服务、部分应用使用
            机器级，通常需要管理员

环境变量 ── HTTP_PROXY / HTTPS_PROXY / ALL_PROXY
            命令行工具、部分开发工具使用
```

最初 6 行 bat 只改了 WinINET 的 `ProxyEnable`，所以：

- PAC 可能还开着
- WinHTTP 可能还走代理
- 已经运行的程序可能没刷新

工具把这三层分开显示，避免“看起来关了，其实没关”。

## 4. 状态机

```text
                 disable
   ┌────────┐  ───────────────▶  ┌─────────┐
   │ ON     │                    │ OFF     │
   │ 有代理 │                    │ 状态已存 │
   └────────┘  ◀───────────────  └─────────┘
        ▲          enable              │
        │                              │ restore
        └──────────────────────────────┘
                  恢复原始状态
```

### 状态文件

`disable` 第一次执行时写入：

```json
{
  "Version": 1,
  "SavedAt": "2026-11-16T...",
  "WinInet": {
    "ProxyEnable": 1,
    "ProxyServer": "127.0.0.1:7890",
    "ProxyOverride": "<local>",
    "AutoConfigURL": ""
  },
  "WinHttp": {
    "Mode": "Direct",
    "Proxy": null,
    "BypassList": null
  }
}
```

状态文件里没有密码，也没有 token。它只保存恢复代理所需的配置。

### 为什么状态文件只写一次

如果用户连续按两次 `disable`，第二次不能把“已经关闭的状态”当成原始状态保存。

所以逻辑是：

```text
if 状态文件不存在:
    保存当前状态
else:
    不覆盖
```

这样 `restore` 永远恢复第一次 `disable` 之前的状态。

## 5. 关键实现

### 5.1 读注册表不要直接点属性

```powershell
$item.ProxyServer
```

在 `Set-StrictMode -Version Latest` 下，如果属性不存在，可能直接抛错。

所以用：

```powershell
$property = $Object.PSObject.Properties[$Name]
if ($null -eq $property) { return $null }
return $property.Value
```

### 5.2 ProxyEnable 必须保持 DWORD

`Set-ItemProperty` 不保证注册表值类型。`ProxyEnable` 需要 `REG_DWORD`，所以用：

```powershell
New-ItemProperty -PropertyType DWord -Force
```

### 5.3 写完要刷新

注册表写入后，已运行的程序不一定立刻生效。工具调用：

```text
InternetSetOption(INTERNET_OPTION_SETTINGS_CHANGED)
InternetSetOption(INTERNET_OPTION_REFRESH)
```

### 5.4 WinHTTP 的输出是本地化的

`netsh winhttp show proxy` 在中文系统上会输出中文标签。

所以解析同时匹配：

```text
Direct access / 直接访问
Proxy Server(s) / 代理服务器
Bypass List / 跳过列表
```

解析不出来时返回 `Unknown`，不猜测。

### 5.5 WinHTTP 失败时保留状态

如果当前不是管理员：

- WinINET 恢复成功
- WinHTTP 显示 `Skipped (needs administrator)`
- **状态文件保留**
- 用户可以用管理员终端再次 `restore`

不会把“部分恢复”当成“完全成功”。

## 6. 为什么需要 DryRun

改代理会直接影响网络。`-DryRun` 让用户在写入前看到：

- 当前 `ProxyEnable`
- 将变成什么
- 是否会保存状态
- 是否会处理 PAC
- 是否会处理 WinHTTP

DryRun 不写状态文件，也不改注册表。

## 7. 测试隔离

测试不碰真实代理，使用：

```text
HKCU\Software\WinProxyToggle\Tests\<guid>
```

测试内容：

```text
初始状态读取
DryRun 不写入
disable 保存状态、设置 0
disable 按需清除 PAC
enable 恢复代理/PAC
restore 恢复全部原始值
restore 删除状态文件
最小注册表键不抛错
状态格式化包含预期段落
```

当前结果：**23 通过，0 失败**。

## 8. 中文注释与编码

注释不会执行，所以不会直接产生 bug。真正需要注意的是：

1. **文件编码**
   - Windows PowerShell 5.1 对无 BOM 的 UTF-8 可能按 ANSI 读取。
   - 本项目所有 `.ps1` / `.psm1` 使用 **UTF-8 with BOM**。
   - 已用 Windows PowerShell 5.1 实际跑过测试。

2. **不要复制代码**
   - 为了写中文说明而复制一份 `.ps1`，两份代码会逐渐不一致。
   - 本项目只保留一份代码；中文说明放在 Markdown 文档里。
   - 代码里只有中文注释，没有第二份逻辑。

3. **注释写“为什么”**
   - 例如“为什么先保存状态”“为什么 WinHTTP 需要管理员”，而不是逐行翻译代码。

## 9. 已知限制

- 不处理应用内代理（插件、IDE 自己的设置）
- 不处理环境变量代理
- WinHTTP 需要管理员权限
- `enable` 不等于 `restore`：`enable` 只打开手动代理，`restore` 才恢复完整历史状态
- 不是安全边界

## 10. 面试讲法

两分钟版本：

> 我先写了一个 6 行 bat 关闭系统代理，后来发现它只改 WinINET，不能恢复，也不处理 PAC 和 WinHTTP。  
> 我把它拆成核心模块 + CLI + 托盘，加了状态保存、DryRun 和隔离测试。  
> AI 帮我查了 Windows 代理层次、生成了初稿，但权限边界、回滚设计和测试隔离是我定的。  
> 最后用 23 个测试和真实只读检查验证。

重点不是“代码多”，而是：

```text
定义问题 → 找失败模式 → 选择最小方案 → 验证 → 复盘
```
