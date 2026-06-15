# PromptStudio 激活授权系统 PRD v1.0

> 文档目的：让 Codex 或工程师在一个上下文窗口内完成 PromptStudio 激活授权功能的开发。本文档是产品、交互、后端、客户端、数据库、安全、隐私、测试和验收的一体化规格说明。除非现有项目技术栈强制要求调整，否则按本文档实现。

---

## 0. Codex 开发总指令

Codex 读取本文档后，需要完成一个可上线的 PromptStudio 激活授权系统。实现时遵守以下硬性规则：

1. 不上传、不扫描、不分析用户的 Prompt 正文、标题、标签名、文件名、本地路径、图片、视频、API Key、剪贴板内容。
2. 授权系统只处理购买邮箱、激活码、设备授权、授权证书、设备数量、版本权益和必要的安全风控信息。
3. 不实现强 DRM，不尝试阻止所有破解；目标是阻止普通盗用、共享激活码和误用，同时保持本地生产力软件的用户信任。
4. 授权失败、过期、撤销、退款、离线超期时，绝不能锁死用户本地数据。用户必须始终可以打开、搜索、复制、导出已有数据。
5. 所有 license code、OTP、token、device private key、signing private key、pepper、encryption key 都不能写入日志。
6. 客户端不能以 `isPro = true` 这种可修改本地字段作为最终授权依据。最终授权依据必须是服务端签名授权证书。
7. 首次激活必须联网；激活后支持离线使用：30 天授权证书有效期 + 14 天宽限期。
8. 每个激活码默认允许 2 台设备，可加购设备位；用户可在 app 内停用当前设备，也可在网页端通过邮箱验证码解绑旧设备。
9. 实现时优先复用现有项目风格、目录结构、HTTP 封装、错误处理、日志组件、设置页面和本地存储组件。
10. 后端默认技术方案为 TypeScript + Fastify + PostgreSQL + Prisma 或等价 ORM；客户端默认技术方案为 macOS Swift/SwiftUI + Keychain Services + CryptoKit。现有项目已有其他栈时，保持本文档的数据模型、API 行为、安全逻辑和验收标准不变。

---

## 1. 背景

PromptStudio 是面向 Prompt 管理、组织、复用和 AI 工作流效率提升的 macOS 本地软件。用户购买软件后，开发者需要向用户发送激活码，用户在 PromptStudio 中输入购买邮箱和激活码完成 Pro 激活。

授权体验参考 Eagle 类本地软件的用户心智：一次性购买、每个 license 支持两台设备、可解绑换机、试用期后激活、用户数据保存在本地。PromptStudio 的底层实现需要更明确地支持设备密钥、服务端签名证书、离线使用、退款撤销、加购设备位、后台风控和隐私边界。

---

## 2. 产品目标

### 2.1 核心目标

1. 用户购买 PromptStudio 后，可以通过「购买邮箱 + 激活码」激活 Pro。
2. 一个激活码默认可激活 2 台设备。
3. 用户换机、重装、设备丢失时，可以自助解绑旧设备。
4. 激活成功后，即使短期离线也能继续使用 Pro 功能。
5. 授权过期、退款、撤销或超期时，不破坏、不锁定、不删除用户本地数据。
6. 后台可以生成、撤销、退款、重置、加购设备位、查看激活事件。
7. 客户端和服务端都实现合理安全边界，避免明文 license code 泄露和本地授权状态被简单篡改。

### 2.2 非目标

1. 不实现账号密码体系。
2. 不实现云同步。
3. 不实现团队协作空间。
4. 不实现订阅扣费和支付网关 webhook；但数据库必须预留订单、退款、套餐和更新权益字段。
5. 不实现硬件序列号采集。
6. 不实现侵入式 DRM、内核级校验、反调试、混淆破解对抗。
7. 不阻止高级逆向攻击者破解；只防止普通盗用、激活码公开传播和误用。

---

## 3. 名词定义

| 名词 | 定义 |
|---|---|
| License | 一份购买授权，对应一个激活码、一个购买邮箱、一个套餐和设备数上限。 |
| License Code | 发给用户的激活码，例如 `PS-7K4D-M9QF-2X8P-R6TA-B3HE-Z5JW-GV`。 |
| Seat | 可激活设备位。默认 2 个。 |
| Activation | 某个 License 在某台设备上的一次激活记录。 |
| Device Identity | 客户端首次激活时生成的设备身份，由 `installId + deviceKeyPair + activationId` 组成。 |
| installId | 客户端随机生成的安装 ID，不使用硬件序列号。服务端只保存 hash。 |
| deviceKeyPair | 客户端生成的 Ed25519 设备密钥对。私钥存 Keychain，公钥发给服务端。 |
| License Certificate | 服务端签名的授权证书，客户端可离线验签。 |
| Trial | 30 天全功能试用，不需要登录。 |
| Grace | 授权证书过期后 14 天宽限期，Pro 功能继续可用，但提示联网刷新。 |
| Limited | 宽限期结束、授权撤销或 Pro 不可用状态。已有数据仍可打开、搜索、复制和导出。 |
| Entitlement | 功能权益，例如批量导入、高级搜索、AI 辅助、导出格式等。 |
| Portal | License 管理网页，用户通过购买邮箱验证码进入，可查看设备并解绑。 |

---

## 4. 最终产品策略

### 4.1 授权模式

PromptStudio v1 使用以下授权模式：

```text
30 天全功能试用 + Pro 一次性买断 + 每个 license 默认 2 台设备 + 可加购设备位
```

### 4.2 默认策略

| 项目 | 默认值 |
|---|---|
| 试用期 | 30 天 |
| 试用是否需要登录 | 不需要 |
| Pro 激活字段 | 购买邮箱 + 激活码 |
| License 默认设备数 | 2 台 |
| 允许平台 | macOS |
| 首次激活 | 必须联网 |
| 本地授权证书有效期 | 30 天 |
| 宽限期 | 14 天 |
| 自助解绑 | 支持 |
| 加购设备位 | 支持数据模型和后台操作，支付入口可后置 |
| 匿名统计 | 可选，用户可关闭 |
| 授权校验 | 必要联网能力，不可关闭 |
| 用户数据保护 | 授权无效时仍可打开、搜索、复制、导出已有数据 |

### 4.3 更新权益

数据库和授权证书必须预留更新权益字段，避免未来商业模式被锁死。

```text
license_type: lifetime | subscription | trial | education | team | beta
plan: pro_lifetime | pro_v1_lifetime | pro_plus_updates | team | education
major_version: 1
updates_until: null 或 ISO 日期
features: string[]
```

v1 默认：

```text
plan = pro_lifetime
license_type = lifetime
major_version = 1
updates_until = null
seat_limit = 2
```

---

## 5. 用户场景

### 5.1 新用户试用

用户首次安装 PromptStudio 后，自动获得 30 天全功能试用。用户不需要注册、登录或输入邮箱。主界面可以显示轻提示：

```text
PromptStudio Pro 试用中 · 剩余 30 天
[输入激活码] [购买 Pro]
```

### 5.2 已购买用户激活

用户收到购买邮件，其中包含购买邮箱和激活码。用户打开 PromptStudio：

```text
设置 → License → 输入激活码
```

输入：

```text
购买邮箱
激活码
```

激活成功后显示：

```text
已激活 PromptStudio Pro
当前设备：MacBook Pro - macOS 15
设备额度：1 / 2
授权类型：Pro Lifetime
```

### 5.3 第二台设备激活

用户在另一台 Mac 上输入同一个购买邮箱和激活码。服务端发现当前激活数未超过 2 台，允许激活。

成功后显示：

```text
已激活 PromptStudio Pro
设备额度：2 / 2
```

### 5.4 设备已满

第三台设备尝试激活同一激活码时，服务端返回设备数已满。客户端展示已激活设备列表，并提供解绑入口。

```text
该激活码已达到 2 台设备上限。

已激活设备：
1. MacBook Pro - macOS 15，最近使用：2026-06-10
2. Mac mini - macOS 14，最近使用：2026-05-28

[解绑旧设备] [加购设备位] [联系支持]
```

### 5.5 当前设备停用

用户在当前设备上点击：

```text
设置 → License → 停用当前设备
```

成功后：

```text
当前设备已停用，此设备不再占用激活名额。
```

客户端删除本地授权证书，但不能删除用户资料库。

### 5.6 旧设备丢失或损坏

用户无法在旧设备上点击停用时，可以访问 License 管理网页：

```text
输入购买邮箱 → 收取验证码 → 查看设备 → 解绑旧设备
```

### 5.7 离线使用

用户激活成功后，即使离线也可以继续使用 Pro。客户端使用本地服务端签名授权证书进行离线验签。

状态：

```text
证书有效期内：Pro 正常
证书过期但宽限期内：Pro 正常，提示联网刷新
宽限期结束：进入 Limited，只限制 Pro 写入/高级能力，不锁数据
```

### 5.8 退款或撤销

后台把 license 标记为 `refunded` 或 `revoked`。客户端下一次联网刷新时进入 Limited。已有离线证书在最长 30 + 14 天内可能继续有效，这是本地软件离线体验的可接受权衡。

---

## 6. 功能范围

### 6.1 MVP 必须完成

1. 30 天本地试用。
2. 激活码生成 CLI。
3. 服务端 license 数据模型。
4. 服务端激活 API。
5. 服务端刷新 challenge API。
6. 服务端刷新授权证书 API。
7. 服务端停用当前设备 API。
8. License 管理网页邮箱验证码登录。
9. License 管理网页设备列表。
10. License 管理网页解绑设备。
11. License 找回邮件。
12. 客户端 Keychain 存储。
13. 客户端设备密钥生成和签名。
14. 客户端授权证书验签。
15. 客户端离线状态机。
16. 客户端激活 UI。
17. 客户端 License 设置页。
18. 客户端 Limited 状态下的数据保护。
19. 后端事件日志。
20. 基础风控和限频。
21. 后端和客户端核心测试。

### 6.2 v1 可后置

1. 支付 webhook 自动生成 license。
2. 完整后台管理 UI。
3. 企业团队 license。
4. 云同步账号体系。
5. 插件市场授权。
6. 复杂反破解措施。

---

## 7. 交互设计

### 7.1 License 设置页

入口：

```text
PromptStudio → Settings → License
```

页面内容按状态展示。

#### Trial 状态

```text
PromptStudio Pro Trial
剩余 18 天

试用期内可使用全部 Pro 功能。试用结束后，你仍可以打开、搜索、复制和导出已有数据。

[输入激活码]
[购买 Pro]
```

#### Pro Active 状态

```text
PromptStudio Pro 已激活

授权邮箱：u***@example.com
授权类型：Pro Lifetime
当前设备：MacBook Pro - macOS 15
设备额度：1 / 2
下次授权刷新：2026-06-22

[管理设备]
[停用当前设备]
```

#### Grace 状态

```text
PromptStudio Pro 需要联网刷新

你的本地授权仍在宽限期内，Pro 功能可继续使用。请在 14 天内联网刷新授权。

[立即刷新]
[管理设备]
```

#### Limited 状态

```text
PromptStudio Pro 当前不可用

你仍可以打开、搜索、复制和导出已有数据。要继续使用 Pro 写入、批量导入、AI 辅助和高级功能，请重新激活。

[输入激活码]
[管理设备]
[导出数据]
```

### 7.2 激活弹窗

字段：

```text
购买邮箱
激活码
```

按钮：

```text
[激活 PromptStudio Pro]
[找回激活码]
```

说明文案：

```text
PromptStudio 需要联网验证激活码并管理设备授权。授权校验不会上传你的 Prompt、文件、图片、API Key 或本地路径。
```

输入校验：

1. 邮箱不能为空，格式基本合法。
2. 激活码自动转大写，自动去除空格，允许用户带或不带横杠输入。
3. 激活按钮点击后进入 loading，避免重复提交。
4. 激活失败展示可理解错误。

### 7.3 激活成功页

```text
激活成功

PromptStudio Pro 已在此设备启用。
设备额度：1 / 2

[完成]
```

### 7.4 设备管理网页

路径：

```text
/license
```

流程：

```text
输入购买邮箱
→ 发送 6 位验证码
→ 输入验证码
→ 显示该邮箱下的 license 列表
→ 进入某个 license 的设备列表
→ 解绑旧设备
```

设备列表字段：

```text
设备名称
平台
系统版本
App 版本
激活时间
最近校验时间
状态
操作：解绑
```

不要展示：

```text
硬件序列号
本地用户名
本地路径
IP 地址
完整 installId
完整 device public key
```

---

## 8. 授权状态机

客户端必须使用统一状态机，不允许在不同页面散落判断逻辑。

```text
NoLicense
  → TrialActive
  → TrialExpired
  → ActivatedPro
  → Grace
  → Limited
  → Revoked
```

### 8.1 状态定义

| 状态 | 条件 | 功能能力 |
|---|---|---|
| NoLicense | 无 trial，无证书 | 自动创建 trial |
| TrialActive | trial_started_at + 30 天内 | 全功能 |
| TrialExpired | 试用过期且无 Pro | 已有数据可打开、搜索、复制、导出；Pro 写入/高级功能限制 |
| ActivatedPro | 证书签名有效且 now <= expiresAt | Pro 全功能 |
| Grace | 签名有效且 expiresAt < now <= graceUntil | Pro 全功能 + 联网刷新提示 |
| Limited | trial 过期、证书过宽限、证书无效、授权不可用 | 已有数据可打开、搜索、复制、导出；Pro 写入/高级功能限制 |
| Revoked | 服务端明确返回 revoked/refunded/disabled | 等同 Limited，展示具体提示 |

### 8.2 状态优先级

判断顺序：

```text
1. 有有效 Pro 证书 → Pro/Grace/Limited
2. 无 Pro 证书 → TrialActive/TrialExpired
3. 服务端最近明确 revoked/refunded → Revoked 优先于本地 trial
4. 证书签名无效 → Limited，不使用 trial 绕过
```

### 8.3 离线时间防回拨

客户端保存 `lastTrustedServerTime` 到 Keychain。每次成功激活或刷新时更新。

本地判断时间使用：

```text
effectiveNow = max(localSystemNow, lastTrustedServerTime)
```

当本地时间明显早于 `lastTrustedServerTime - 24h` 时，展示提示：

```text
系统时间可能不正确，授权状态可能无法刷新。
```

不要因为单纯时间异常删除用户数据。

---

## 9. 功能权益和限制

### 9.1 Entitlement 枚举

客户端和服务端共用这些 feature key：

```text
base_open_library
base_search
base_copy
base_export_basic
pro_unlimited_items
pro_create_edit
pro_batch_import
pro_advanced_search
pro_ai_assist
pro_export_all_formats
pro_custom_variables
pro_collections
pro_templates
```

### 9.2 Free/Limited 必须保留

```text
base_open_library
base_search
base_copy
base_export_basic
```

### 9.3 Pro 解锁

```text
pro_unlimited_items
pro_create_edit
pro_batch_import
pro_advanced_search
pro_ai_assist
pro_export_all_formats
pro_custom_variables
pro_collections
pro_templates
```

### 9.4 客户端统一判断

所有需要授权的功能通过统一接口判断：

```swift
licenseManager.canUse(.proBatchImport)
licenseManager.require(.proAIAssist) { ... }
```

禁止在业务代码里直接判断 `licenseState == .pro`。

---

## 10. 总体技术架构

### 10.1 客户端模块

| 模块 | 职责 |
|---|---|
| LicenseManager | 授权状态核心管理，启动时解析状态，触发刷新，提供 canUse 接口。 |
| TrialManager | 30 天试用创建、读取、过期判断。 |
| DeviceIdentityManager | 生成和读取 installId、deviceKeyPair、deviceLabel。 |
| KeychainLicenseStore | Keychain 读写 installId、device private key、license certificate、activationId、lastTrustedServerTime。 |
| LicenseAPIClient | 调用授权服务端 API。 |
| LicenseCertificateVerifier | 验证服务端签名证书。 |
| FeatureGate | UI 和业务能力 gating。 |
| ActivationViewModel | 激活弹窗业务逻辑。 |
| LicenseSettingsView | License 设置页。 |
| DeviceManagementLinkView | 打开网页设备管理入口。 |

### 10.2 后端模块

| 模块 | 职责 |
|---|---|
| LicenseService | 创建、查询、撤销、退款、加购、重置 license。 |
| ActivationService | 激活、刷新、停用设备、设备列表。 |
| CertificateService | 生成服务端签名授权证书。 |
| DeviceProofService | 验证设备公钥签名。 |
| OTPService | 邮箱验证码发送、校验、会话创建。 |
| PortalService | License 管理网页会话和设备操作。 |
| TelemetryService | 匿名统计接收，可关闭。 |
| RateLimitService | 限频和风控。 |
| AuditEventService | 记录 license_events。 |
| AdminCLI | 生成 license、撤销、加购设备位、重置激活码。 |

### 10.3 数据流

```text
购买完成/手动创建 license
→ 后台生成激活码
→ 用户收到邮件
→ 客户端输入邮箱 + 激活码
→ 客户端生成 installId + deviceKeyPair
→ 服务端校验 license 和 seat
→ 服务端创建 activation
→ 服务端签发 license certificate
→ 客户端保存到 Keychain
→ 后续启动离线验签
→ 到 refreshAfter 后后台静默刷新
```

---

## 11. License Code 规范

### 11.1 格式

激活码格式：

```text
PS-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX
```

说明：

1. `PS` 是产品前缀。
2. X 使用 Crockford Base32 字符集，排除容易混淆的 `O`、`I`、`L`、`U`。
3. 随机主体长度 26 个字符，约 130-bit 随机强度。
4. 展示时带横杠，输入时允许不带横杠。

示例：

```text
PS-7K4D-M9QF-2X8P-R6TA-B3HE-Z5JW-GV
```

### 11.2 归一化

服务端和客户端统一归一化：

```text
trim
uppercase
remove spaces
remove hyphens
保留 A-Z 和 0-9
```

`PS-7K4D-M9QF` 和 `ps 7k4d m9qf` 应视作同一个 code。

### 11.3 存储

数据库保存：

```text
code_prefix: 前 7 位展示片段，例如 PS-7K4D
code_suffix: 最后 4 位，例如 JWGV
code_hash: HMAC_SHA256(LICENSE_CODE_PEPPER, normalized_code)
code_encrypted: AES-256-GCM(normalized_display_code)
```

说明：

1. 校验时只使用 `code_hash`。
2. 找回邮件需要发送原激活码，所以保存加密后的 `code_encrypted`。
3. 所有日志必须 redaction：只允许记录 `code_prefix`，不记录完整 code。
4. 管理后台默认只展示 `code_prefix + **** + code_suffix`。

---

## 12. 设备身份规范

### 12.1 不采集的信息

禁止采集：

```text
Mac 序列号
硬盘序列号
网卡 MAC 地址
本地用户名
用户目录路径
PromptStudio 资料库路径
文件名
真实设备账户名
```

### 12.2 设备身份组成

```text
installId: 128-bit random UUID 或 random bytes
installIdHash: SHA256("install:" + installId)
deviceKeyPair: Ed25519 signing key pair
activationId: 服务端创建
```

### 12.3 Keychain 存储

Keychain keys：

```text
com.promptstudio.license.installId
com.promptstudio.license.devicePrivateKey
com.promptstudio.license.devicePublicKey
com.promptstudio.license.activationId
com.promptstudio.license.certificate
com.promptstudio.license.lastTrustedServerTime
com.promptstudio.license.trialRecord
```

Keychain accessibility：

```text
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

目的：尽量避免通过系统迁移或备份把设备私钥复制到另一台设备。

### 12.4 设备昵称

客户端生成默认昵称：

```text
Mac - macOS 15
MacBook Pro - macOS 15
Mac mini - macOS 14
```

设备昵称不要包含本地用户名。允许用户在设备管理页重命名，但 v1 可不实现重命名。

---

## 13. 授权证书规范

### 13.1 签名算法

服务端授权证书使用 Ed25519 签名。

```text
服务端保存 signing private key
客户端内置 signing public key
证书携带 kid 支持未来轮换
```

### 13.2 证书格式

使用自定义 compact 格式，避免引入复杂 JWT 依赖：

```text
PSCERT1.<payload_base64url>.<signature_base64url>
```

签名内容：

```text
payload_base64url 的 UTF-8 bytes
```

payload 必须是 canonical JSON：

```text
UTF-8
对象 key 按字典序排序
无多余空格
日期使用 ISO-8601 UTC
```

### 13.3 payload 字段

```json
{
  "version": 1,
  "iss": "promptstudio-license-server",
  "aud": "promptstudio-macos",
  "bundleId": "com.promptstudio.app",
  "kid": "license_signing_key_2026_01",
  "licenseId": "lic_01J...",
  "activationId": "act_01J...",
  "customerEmailHash": "sha256...",
  "plan": "pro_lifetime",
  "licenseType": "lifetime",
  "seatLimit": 2,
  "features": [
    "base_open_library",
    "base_search",
    "base_copy",
    "base_export_basic",
    "pro_unlimited_items",
    "pro_create_edit",
    "pro_batch_import",
    "pro_advanced_search",
    "pro_ai_assist",
    "pro_export_all_formats",
    "pro_custom_variables",
    "pro_collections",
    "pro_templates"
  ],
  "majorVersion": 1,
  "updatesUntil": null,
  "status": "active",
  "issuedAt": "2026-06-15T00:00:00Z",
  "expiresAt": "2026-07-15T00:00:00Z",
  "graceUntil": "2026-07-29T00:00:00Z",
  "refreshAfter": "2026-06-22T00:00:00Z"
}
```

### 13.4 客户端验签要求

客户端必须验证：

```text
1. 格式前缀是 PSCERT1
2. payload 可解析
3. kid 对应内置 public key
4. Ed25519 签名有效
5. aud == promptstudio-macos
6. bundleId == 当前 app bundle id
7. activationId == Keychain 中 activationId
8. status == active
9. 当前 app major version 符合 majorVersion / updatesUntil 规则
10. effectiveNow <= graceUntil 才可继续 Pro/Grace
```

---

## 14. 后端数据模型

### 14.1 customers

```sql
CREATE TABLE customers (
  id TEXT PRIMARY KEY,
  email_hash TEXT NOT NULL UNIQUE,
  email_encrypted TEXT NOT NULL,
  name_encrypted TEXT,
  country TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 14.2 orders

```sql
CREATE TABLE orders (
  id TEXT PRIMARY KEY,
  customer_id TEXT NOT NULL REFERENCES customers(id),
  provider TEXT NOT NULL DEFAULT 'manual',
  provider_order_id TEXT,
  amount_cents INTEGER,
  currency TEXT,
  status TEXT NOT NULL DEFAULT 'paid',
  purchased_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  refunded_at TIMESTAMPTZ,
  raw_event_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_orders_customer_id ON orders(customer_id);
```

### 14.3 licenses

```sql
CREATE TABLE licenses (
  id TEXT PRIMARY KEY,
  customer_id TEXT NOT NULL REFERENCES customers(id),
  order_id TEXT REFERENCES orders(id),
  code_prefix TEXT NOT NULL,
  code_suffix TEXT NOT NULL,
  code_hash TEXT NOT NULL UNIQUE,
  code_encrypted TEXT NOT NULL,
  plan TEXT NOT NULL DEFAULT 'pro_lifetime',
  license_type TEXT NOT NULL DEFAULT 'lifetime',
  seat_limit INTEGER NOT NULL DEFAULT 2,
  status TEXT NOT NULL DEFAULT 'unused',
  major_version INTEGER NOT NULL DEFAULT 1,
  updates_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  revoked_reason TEXT,
  notes TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_licenses_customer_id ON licenses(customer_id);
CREATE INDEX idx_licenses_status ON licenses(status);
```

Allowed `licenses.status`：

```text
unused
active
limited
refunded
revoked
disabled
```

### 14.4 activations

```sql
CREATE TABLE activations (
  id TEXT PRIMARY KEY,
  license_id TEXT NOT NULL REFERENCES licenses(id),
  install_id_hash TEXT NOT NULL,
  device_public_key TEXT NOT NULL,
  device_public_key_hash TEXT NOT NULL,
  device_label TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'macos',
  os_version TEXT,
  app_version TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  activated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ,
  deactivated_at TIMESTAMPTZ,
  deactivated_reason TEXT,
  risk_score INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_activations_license_id ON activations(license_id);
CREATE INDEX idx_activations_status ON activations(status);
CREATE UNIQUE INDEX idx_activations_unique_active_device
  ON activations(license_id, install_id_hash, device_public_key_hash)
  WHERE status = 'active';
```

Allowed `activations.status`：

```text
active
deactivated
revoked
stale
```

### 14.5 license_certificates

```sql
CREATE TABLE license_certificates (
  id TEXT PRIMARY KEY,
  license_id TEXT NOT NULL REFERENCES licenses(id),
  activation_id TEXT NOT NULL REFERENCES activations(id),
  kid TEXT NOT NULL,
  certificate_hash TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  grace_until TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_license_certificates_activation_id ON license_certificates(activation_id);
```

### 14.6 license_events

```sql
CREATE TABLE license_events (
  id TEXT PRIMARY KEY,
  license_id TEXT REFERENCES licenses(id),
  activation_id TEXT REFERENCES activations(id),
  event_type TEXT NOT NULL,
  event_source TEXT NOT NULL,
  ip_hash TEXT,
  user_agent_hash TEXT,
  metadata_json JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_license_events_license_id ON license_events(license_id);
CREATE INDEX idx_license_events_activation_id ON license_events(activation_id);
CREATE INDEX idx_license_events_event_type ON license_events(event_type);
CREATE INDEX idx_license_events_created_at ON license_events(created_at);
```

### 14.7 email_otps

```sql
CREATE TABLE email_otps (
  id TEXT PRIMARY KEY,
  email_hash TEXT NOT NULL,
  otp_hash TEXT NOT NULL,
  purpose TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_email_otps_email_hash ON email_otps(email_hash);
CREATE INDEX idx_email_otps_expires_at ON email_otps(expires_at);
```

Allowed `purpose`：

```text
license_portal
license_recover
```

### 14.8 portal_sessions

```sql
CREATE TABLE portal_sessions (
  id TEXT PRIMARY KEY,
  email_hash TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ
);

CREATE INDEX idx_portal_sessions_email_hash ON portal_sessions(email_hash);
```

### 14.9 refresh_challenges

```sql
CREATE TABLE refresh_challenges (
  id TEXT PRIMARY KEY,
  activation_id TEXT NOT NULL REFERENCES activations(id),
  nonce_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_refresh_challenges_activation_id ON refresh_challenges(activation_id);
```

### 14.10 license_key_rotations

```sql
CREATE TABLE license_key_rotations (
  id TEXT PRIMARY KEY,
  old_license_id TEXT NOT NULL REFERENCES licenses(id),
  new_code_prefix TEXT NOT NULL,
  new_code_suffix TEXT NOT NULL,
  reason TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by TEXT
);
```

---

## 15. 环境变量

后端必须支持以下环境变量：

```text
DATABASE_URL
LICENSE_CODE_PEPPER
EMAIL_HASH_PEPPER
IP_HASH_PEPPER
TOKEN_HASH_PEPPER
DATA_ENCRYPTION_KEY_B64
LICENSE_SIGNING_PRIVATE_KEY_B64
LICENSE_SIGNING_PUBLIC_KEY_B64
LICENSE_SIGNING_KEY_ID
APP_BUNDLE_ID=com.promptstudio.app
LICENSE_CERT_TTL_DAYS=30
LICENSE_CERT_GRACE_DAYS=14
LICENSE_REFRESH_AFTER_DAYS=7
PORTAL_SESSION_TTL_MINUTES=30
OTP_TTL_MINUTES=10
SMTP_HOST
SMTP_PORT
SMTP_USER
SMTP_PASS
SMTP_FROM
ADMIN_TOKEN
APP_LICENSE_PORTAL_URL
```

所有 key 必须通过环境变量注入，不能写死在源码里。测试环境可以使用 `.env.test`。

---

## 16. API 通用规范

### 16.1 Base URL

```text
https://license.promptstudio.app
```

本地开发：

```text
http://localhost:8787
```

### 16.2 版本

所有 API 使用：

```text
/v1
```

### 16.3 成功响应

```json
{
  "ok": true,
  "data": {}
}
```

### 16.4 错误响应

```json
{
  "ok": false,
  "error": {
    "code": "SEAT_LIMIT_EXCEEDED",
    "message": "该激活码已达到设备上限。",
    "requestId": "req_01J..."
  }
}
```

### 16.5 常用错误码

| code | HTTP | 含义 | 客户端文案 |
|---|---:|---|---|
| INVALID_INPUT | 400 | 参数错误 | 请检查输入内容。 |
| INVALID_LICENSE | 401 | 邮箱或激活码不匹配 | 邮箱或激活码不匹配，请检查购买邮件。 |
| LICENSE_DISABLED | 403 | license disabled | 该激活码当前不可用，请联系支持。 |
| LICENSE_REVOKED | 403 | license revoked | 该激活码已被撤销，请联系支持。 |
| LICENSE_REFUNDED | 403 | 已退款 | 该激活码当前不可用。 |
| SEAT_LIMIT_EXCEEDED | 409 | 超过设备数 | 该激活码已达到设备上限，请解绑旧设备或加购设备位。 |
| DEVICE_PROOF_INVALID | 401 | 设备签名无效 | 当前设备验证失败，请重新激活。 |
| CHALLENGE_EXPIRED | 401 | challenge 过期 | 授权刷新已过期，请重试。 |
| RATE_LIMITED | 429 | 限频 | 操作过于频繁，请稍后再试。 |
| SERVER_ERROR | 500 | 服务端异常 | 授权服务暂时不可用，请稍后再试。 |

### 16.6 日志脱敏

请求日志必须脱敏：

```text
licenseCode → [REDACTED]
otp → [REDACTED]
signature → [REDACTED]
devicePublicKey → hash only
email → emailHash only
```

---

## 17. Public API 详细规格

### 17.1 激活 license

```http
POST /v1/licenses/activate
```

请求：

```json
{
  "email": "user@example.com",
  "licenseCode": "PS-7K4D-M9QF-2X8P-R6TA-B3HE-Z5JW-GV",
  "installIdHash": "sha256...",
  "devicePublicKey": "base64url-ed25519-public-key",
  "deviceProof": "base64url-signature",
  "deviceLabel": "MacBook Pro - macOS 15",
  "platform": "macos",
  "appVersion": "1.0.0",
  "osVersion": "macOS 15.5"
}
```

`deviceProof` 签名内容：

```text
PS_ACTIVATE_V1:{installIdHash}:{devicePublicKey}:{platform}:{appVersion}
```

响应：

```json
{
  "ok": true,
  "data": {
    "activationId": "act_01J...",
    "licenseCertificate": "PSCERT1.xxx.yyy",
    "refreshAfter": "2026-06-22T00:00:00Z",
    "deviceCount": 1,
    "seatLimit": 2,
    "serverTime": "2026-06-15T00:00:00Z"
  }
}
```

服务端逻辑：

```text
1. normalize email 和 licenseCode。
2. emailHash = HMAC/sha256 派生。
3. codeHash = HMAC_SHA256(LICENSE_CODE_PEPPER, normalizedCode)。
4. 查询 license。
5. 校验 customer emailHash 是否匹配。
6. 校验 license.status：unused/active/limited 可激活；refunded/revoked/disabled 不可激活。
7. 用请求中的 devicePublicKey 验证 deviceProof。
8. 判断是否已有相同 licenseId + installIdHash + devicePublicKeyHash 的 active activation。
9. 已存在则复用 activation，不重复占 seat。
10. 不存在则统计 active activation 数量。
11. active 数量 >= seat_limit 返回 SEAT_LIMIT_EXCEEDED，并附带可展示设备列表。
12. 未超限则创建 activation。
13. license.status 从 unused 更新为 active；activated_at 首次写入。
14. 签发 certificate。
15. 记录 license_events.activation_success。
```

SEAT_LIMIT_EXCEEDED 响应可带设备列表：

```json
{
  "ok": false,
  "error": {
    "code": "SEAT_LIMIT_EXCEEDED",
    "message": "该激活码已达到设备上限。",
    "requestId": "req_01J..."
  },
  "data": {
    "seatLimit": 2,
    "devices": [
      {
        "activationId": "act_01J...",
        "deviceLabel": "MacBook Pro - macOS 15",
        "platform": "macos",
        "osVersion": "macOS 15.5",
        "appVersion": "1.0.0",
        "activatedAt": "2026-06-01T00:00:00Z",
        "lastSeenAt": "2026-06-10T00:00:00Z"
      }
    ]
  }
}
```

### 17.2 创建刷新 challenge

```http
POST /v1/licenses/refresh/challenge
```

请求：

```json
{
  "activationId": "act_01J..."
}
```

响应：

```json
{
  "ok": true,
  "data": {
    "challengeId": "chg_01J...",
    "nonce": "base64url-random-32bytes",
    "expiresAt": "2026-06-15T00:10:00Z",
    "serverTime": "2026-06-15T00:00:00Z"
  }
}
```

服务端逻辑：

```text
1. 查询 activation。
2. 不存在返回 INVALID_LICENSE，不透露过多信息。
3. 创建 nonce，保存 nonce_hash。
4. challenge 10 分钟过期，只能使用一次。
```

### 17.3 刷新授权证书

```http
POST /v1/licenses/refresh
```

请求：

```json
{
  "activationId": "act_01J...",
  "challengeId": "chg_01J...",
  "nonce": "base64url-random-32bytes",
  "signature": "base64url-signature",
  "appVersion": "1.0.3",
  "osVersion": "macOS 15.5"
}
```

签名内容：

```text
PS_REFRESH_V1:{activationId}:{challengeId}:{nonce}
```

响应：

```json
{
  "ok": true,
  "data": {
    "licenseCertificate": "PSCERT1.xxx.yyy",
    "status": "active",
    "refreshAfter": "2026-06-22T00:00:00Z",
    "serverTime": "2026-06-15T00:00:00Z"
  }
}
```

服务端逻辑：

```text
1. 查询 activation。
2. 查询 challenge，校验 activationId、nonce_hash、expires_at、consumed_at。
3. 用 activation.device_public_key 验证 signature。
4. 查询 license。
5. license.status 为 refunded/revoked/disabled 时返回对应错误。
6. activation.status 非 active 时返回 LICENSE_DISABLED。
7. 更新 activation.last_seen_at、app_version、os_version。
8. challenge 标记 consumed。
9. 签发新 certificate。
10. 记录 refresh_success。
```

### 17.4 停用当前设备

```http
POST /v1/licenses/deactivate
```

请求：

```json
{
  "activationId": "act_01J...",
  "challengeId": "chg_01J...",
  "nonce": "base64url-random-32bytes",
  "signature": "base64url-signature",
  "reason": "user_requested"
}
```

签名内容：

```text
PS_DEACTIVATE_V1:{activationId}:{challengeId}:{nonce}:{reason}
```

响应：

```json
{
  "ok": true,
  "data": {
    "deactivated": true,
    "serverTime": "2026-06-15T00:00:00Z"
  }
}
```

服务端逻辑：

```text
1. 与 refresh 相同方式校验 challenge 和 signature。
2. activation.status 更新为 deactivated。
3. deactivated_at = now。
4. deactivated_reason = reason。
5. 记录 device_deactivated。
```

客户端成功后：

```text
1. 删除 Keychain 中 license certificate。
2. 删除 activationId。
3. 保留 installId 和 deviceKeyPair 可选；推荐保留，重新激活同设备时更稳定。
4. 切换到 TrialExpired 或 Limited，不删除任何资料库。
```

### 17.5 找回激活码

```http
POST /v1/licenses/recover
```

请求：

```json
{
  "email": "user@example.com"
}
```

响应永远返回：

```json
{
  "ok": true,
  "data": {
    "message": "如果该邮箱存在购买记录，我们会发送激活信息。"
  }
}
```

服务端逻辑：

```text
1. normalize email，计算 emailHash。
2. 无论是否找到用户，都返回 ok，防止枚举邮箱。
3. 找到 license 时，向购买邮箱发送 license 信息邮件。
4. 邮件中可以包含完整激活码，来源是 code_encrypted 解密结果。
5. 记录 license_recovered 事件。
6. 对同一 emailHash 做频率限制：每小时最多 3 次，每天最多 10 次。
```

### 17.6 发送 Portal 邮箱验证码

```http
POST /v1/auth/email-otp/send
```

请求：

```json
{
  "email": "user@example.com",
  "purpose": "license_portal"
}
```

响应永远返回：

```json
{
  "ok": true,
  "data": {
    "message": "如果该邮箱存在购买记录，我们会发送验证码。"
  }
}
```

验证码：

```text
6 位数字
10 分钟有效
最多尝试 5 次
otp_hash = HMAC_SHA256(TOKEN_HASH_PEPPER, emailHash + ':' + otp)
```

### 17.7 校验 Portal 邮箱验证码

```http
POST /v1/auth/email-otp/verify
```

请求：

```json
{
  "email": "user@example.com",
  "purpose": "license_portal",
  "otp": "123456"
}
```

响应：

```json
{
  "ok": true,
  "data": {
    "sessionToken": "portal_session_token_only_for_native_clients",
    "expiresAt": "2026-06-15T00:30:00Z"
  }
}
```

网页端也可以设置 HttpOnly Secure SameSite=Lax cookie：

```text
ps_license_session=...
```

### 17.8 Portal license 列表

```http
GET /v1/portal/licenses
```

认证：Portal session cookie 或 Bearer portal session token。

响应：

```json
{
  "ok": true,
  "data": {
    "licenses": [
      {
        "licenseId": "lic_01J...",
        "codePrefix": "PS-7K4D",
        "codeSuffix": "JWGV",
        "plan": "pro_lifetime",
        "licenseType": "lifetime",
        "seatLimit": 2,
        "activeDeviceCount": 2,
        "status": "active",
        "createdAt": "2026-06-01T00:00:00Z"
      }
    ]
  }
}
```

### 17.9 Portal 设备列表

```http
GET /v1/portal/licenses/:licenseId/devices
```

响应：

```json
{
  "ok": true,
  "data": {
    "licenseId": "lic_01J...",
    "seatLimit": 2,
    "devices": [
      {
        "activationId": "act_01J...",
        "deviceLabel": "MacBook Pro - macOS 15",
        "platform": "macos",
        "osVersion": "macOS 15.5",
        "appVersion": "1.0.3",
        "status": "active",
        "activatedAt": "2026-06-01T00:00:00Z",
        "lastSeenAt": "2026-06-10T00:00:00Z"
      }
    ]
  }
}
```

### 17.10 Portal 解绑设备

```http
POST /v1/portal/licenses/:licenseId/activations/:activationId/deactivate
```

请求：

```json
{
  "reason": "portal_user_requested"
}
```

响应：

```json
{
  "ok": true,
  "data": {
    "deactivated": true
  }
}
```

服务端逻辑：

```text
1. 校验 portal session 的 emailHash 是否属于该 license.customer_id。
2. 校验 activation 属于该 license。
3. 频率限制。
4. 更新 activation.status = deactivated。
5. 记录 device_deactivated。
```

### 17.11 匿名统计

```http
POST /v1/telemetry/events
```

请求：

```json
{
  "installIdHash": "sha256...",
  "appVersion": "1.0.3",
  "osVersion": "macOS 15.5",
  "events": [
    {
      "name": "app_launched",
      "timestamp": "2026-06-15T00:00:00Z",
      "properties": {
        "licenseState": "pro_active"
      }
    }
  ]
}
```

限制：

```text
1. 用户可在设置中关闭匿名统计。
2. 不允许发送 Prompt 内容、标题、标签、文件名、路径、API Key、剪贴板内容。
3. 服务端必须丢弃未知高风险字段，例如 content、text、prompt、path、fileName、apiKey、clipboard。
```

---

## 18. Admin CLI

必须实现命令行工具，方便手动发码。

### 18.1 创建 license

```bash
pnpm license:create \
  --email user@example.com \
  --plan pro_lifetime \
  --seats 2 \
  --provider manual \
  --order-id manual_20260615_001
```

输出：

```text
License created
Email: user@example.com
License: PS-7K4D-M9QF-2X8P-R6TA-B3HE-Z5JW-GV
Seats: 2
Plan: pro_lifetime
```

要求：

```text
1. 完整 license code 只在创建时输出一次。
2. 数据库保存 code_hash 和 code_encrypted。
3. CLI 日志文件不能记录完整 code。
```

### 18.2 加购设备位

```bash
pnpm license:add-seats --license-id lic_01J... --seats 1
```

### 18.3 撤销 license

```bash
pnpm license:revoke --license-id lic_01J... --reason chargeback
```

### 18.4 标记退款

```bash
pnpm license:refund --license-id lic_01J... --reason refunded_by_support
```

### 18.5 重置激活码

```bash
pnpm license:rotate-code --license-id lic_01J... --reason leaked
```

逻辑：

```text
1. 生成新 code。
2. 更新 licenses.code_hash/code_encrypted/code_prefix/code_suffix。
3. 已有 active activation 继续有效，直到证书过期或刷新。
4. 新设备激活必须使用新 code。
5. 记录 license_key_rotations 和 license_events。
```

---

## 19. 后端核心业务逻辑

### 19.1 normalizeEmail

```ts
function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}
```

不要对 Gmail 做去点、去 plus 等特殊规则，避免误合并不同用户。

### 19.2 hashEmail

```ts
emailHash = sha256(EMAIL_HASH_PEPPER + ':' + normalizeEmail(email))
```

### 19.3 hashLicenseCode

```ts
codeHash = hmacSha256(LICENSE_CODE_PEPPER, normalizeLicenseCode(code))
```

### 19.4 加密 email/code

使用 AES-256-GCM：

```text
DATA_ENCRYPTION_KEY_B64 解码得到 32 bytes key
ciphertext 格式：base64url(nonce).base64url(ciphertext).base64url(tag)
```

### 19.5 issueCertificate

输入：

```text
license
activation
customerEmailHash
now
```

计算：

```text
issuedAt = now
expiresAt = now + LICENSE_CERT_TTL_DAYS
refreshAfter = now + LICENSE_REFRESH_AFTER_DAYS
graceUntil = expiresAt + LICENSE_CERT_GRACE_DAYS
```

返回：

```text
PSCERT1.payload.signature
```

并写入 `license_certificates`。

### 19.6 active device count

只统计：

```sql
WHERE license_id = ? AND status = 'active'
```

已 deactivated/revoked/stale 不占 seat。

### 19.7 风控规则

| 规则 | 阈值 | 行为 |
|---|---:|---|
| 同一 email recover | 每小时 3 次，每天 10 次 | 429 |
| 同一 license 激活失败 | 每小时 10 次 | 429 |
| 同一 IP 激活失败 | 每小时 30 次 | 429 |
| 同一 license portal 解绑 | 每天 3 次直接允许，30 天 10 次直接允许 | 超过后要求稍后再试或联系支持 |
| 同一 license 高频跨地区激活 | 风险标记 | 不自动封禁，记录 risk_detected |

v1 可以先实现简单内存/数据库限频；生产建议 Redis。

---

## 20. 客户端实现规格 Swift/macOS

### 20.1 目录建议

按现有项目结构调整；没有现有结构时使用：

```text
PromptStudio/
  Licensing/
    LicenseManager.swift
    LicenseState.swift
    Entitlement.swift
    TrialManager.swift
    DeviceIdentityManager.swift
    KeychainLicenseStore.swift
    LicenseAPIClient.swift
    LicenseCertificate.swift
    LicenseCertificateVerifier.swift
    FeatureGate.swift
    ActivationView.swift
    ActivationViewModel.swift
    LicenseSettingsView.swift
```

### 20.2 LicenseState

```swift
enum LicenseState: Equatable {
    case trialActive(daysRemaining: Int)
    case trialExpired
    case proActive(certificate: LicenseCertificate)
    case grace(certificate: LicenseCertificate, daysRemaining: Int)
    case limited(reason: LimitedReason)
    case revoked(reason: RevokedReason)
}
```

### 20.3 Entitlement

```swift
enum Entitlement: String, Codable, CaseIterable {
    case baseOpenLibrary = "base_open_library"
    case baseSearch = "base_search"
    case baseCopy = "base_copy"
    case baseExportBasic = "base_export_basic"
    case proUnlimitedItems = "pro_unlimited_items"
    case proCreateEdit = "pro_create_edit"
    case proBatchImport = "pro_batch_import"
    case proAdvancedSearch = "pro_advanced_search"
    case proAIAssist = "pro_ai_assist"
    case proExportAllFormats = "pro_export_all_formats"
    case proCustomVariables = "pro_custom_variables"
    case proCollections = "pro_collections"
    case proTemplates = "pro_templates"
}
```

### 20.4 LicenseManager 启动逻辑

伪代码：

```swift
func start() async {
    let localState = resolveLocalState()
    publish(localState)

    if shouldRefresh(localState), network.isReachable {
        do {
            let refreshed = try await refreshLicense()
            publish(refreshed)
        } catch {
            publish(resolveLocalStateAfterRefreshFailure(error))
        }
    }
}
```

### 20.5 本地状态解析

```swift
func resolveLocalState() -> LicenseState {
    guard let certString = keychain.loadCertificate() else {
        return trialManager.resolveTrialState()
    }

    guard let cert = verifier.verifyAndDecode(certString) else {
        return .limited(reason: .invalidCertificate)
    }

    guard cert.activationId == keychain.activationId else {
        return .limited(reason: .deviceMismatch)
    }

    let now = max(Date(), keychain.lastTrustedServerTime ?? Date.distantPast)

    if now <= cert.expiresAt {
        return .proActive(certificate: cert)
    }

    if now <= cert.graceUntil {
        return .grace(certificate: cert, daysRemaining: daysBetween(now, cert.graceUntil))
    }

    return .limited(reason: .certificateExpired)
}
```

### 20.6 激活逻辑

```swift
func activate(email: String, code: String) async throws {
    let identity = try deviceIdentityManager.loadOrCreateIdentity()
    let proofPayload = "PS_ACTIVATE_V1:\(identity.installIdHash):\(identity.publicKey):macos:\(appVersion)"
    let proof = try identity.sign(proofPayload)

    let response = try await api.activate(
        email: email,
        licenseCode: code,
        installIdHash: identity.installIdHash,
        devicePublicKey: identity.publicKey,
        deviceProof: proof,
        deviceLabel: identity.deviceLabel,
        platform: "macos",
        appVersion: appVersion,
        osVersion: osVersion
    )

    try verifier.assertValid(response.licenseCertificate)
    keychain.saveActivationId(response.activationId)
    keychain.saveCertificate(response.licenseCertificate)
    keychain.saveLastTrustedServerTime(response.serverTime)

    publish(resolveLocalState())
}
```

### 20.7 刷新逻辑

```swift
func refreshLicense() async throws -> LicenseState {
    let activationId = try keychain.requireActivationId()
    let identity = try deviceIdentityManager.requireIdentity()

    let challenge = try await api.createRefreshChallenge(activationId: activationId)
    let payload = "PS_REFRESH_V1:\(activationId):\(challenge.challengeId):\(challenge.nonce)"
    let signature = try identity.sign(payload)

    let response = try await api.refresh(
        activationId: activationId,
        challengeId: challenge.challengeId,
        nonce: challenge.nonce,
        signature: signature,
        appVersion: appVersion,
        osVersion: osVersion
    )

    try verifier.assertValid(response.licenseCertificate)
    keychain.saveCertificate(response.licenseCertificate)
    keychain.saveLastTrustedServerTime(response.serverTime)

    return resolveLocalState()
}
```

### 20.8 停用当前设备

```swift
func deactivateCurrentDevice() async throws {
    let activationId = try keychain.requireActivationId()
    let identity = try deviceIdentityManager.requireIdentity()

    let challenge = try await api.createRefreshChallenge(activationId: activationId)
    let reason = "user_requested"
    let payload = "PS_DEACTIVATE_V1:\(activationId):\(challenge.challengeId):\(challenge.nonce):\(reason)"
    let signature = try identity.sign(payload)

    try await api.deactivate(
        activationId: activationId,
        challengeId: challenge.challengeId,
        nonce: challenge.nonce,
        signature: signature,
        reason: reason
    )

    keychain.deleteCertificate()
    keychain.deleteActivationId()
    publish(trialManager.resolveTrialState())
}
```

### 20.9 TrialManager

试用记录：

```json
{
  "trialId": "trial_...",
  "startedAt": "2026-06-15T00:00:00Z",
  "lastSeenAt": "2026-06-15T00:00:00Z",
  "version": 1
}
```

存储策略：

```text
1. Keychain 存一份。
2. Application Support 存一份本地 trial 文件。
3. 两份都存在时取 startedAt 更早的一份。
4. lastSeenAt 防止明显时间回拨。
5. 试用防重置只做低强度，不牺牲正常用户体验。
```

### 20.10 FeatureGate

```swift
func canUse(_ entitlement: Entitlement) -> Bool {
    switch state {
    case .trialActive:
        return true
    case .proActive(let cert), .grace(let cert, _):
        return cert.features.contains(entitlement.rawValue)
    case .trialExpired, .limited, .revoked:
        return entitlement.rawValue.hasPrefix("base_")
    }
}
```

业务调用：

```swift
guard licenseManager.canUse(.proBatchImport) else {
    licenseManager.showUpgradePrompt(for: .proBatchImport)
    return
}
```

### 20.11 网络失败处理

激活时网络失败：

```text
无法连接授权服务器，请检查网络或代理设置。
```

刷新时网络失败：

```text
保持当前本地状态，不降级。
```

只有在本地证书本身过期超过宽限期时才进入 Limited。

---

## 21. 邮件模板

### 21.1 购买后发码邮件

标题：

```text
你的 PromptStudio Pro 激活码
```

正文：

```text
感谢购买 PromptStudio Pro。

购买邮箱：{{email}}
激活码：{{licenseCode}}
可激活设备：{{seatLimit}} 台

激活方式：
打开 PromptStudio → Settings → License → 输入购买邮箱和激活码。

管理设备：{{portalUrl}}

PromptStudio 的授权校验不会上传你的 Prompt、文件、图片、API Key 或本地路径。
```

### 21.2 验证码邮件

标题：

```text
你的 PromptStudio 验证码
```

正文：

```text
验证码：{{otp}}

该验证码 10 分钟内有效。不是你本人操作，可以忽略这封邮件。
```

### 21.3 找回激活码邮件

标题：

```text
你的 PromptStudio 激活信息
```

正文：

```text
以下是该邮箱关联的 PromptStudio license：

授权类型：{{plan}}
激活码：{{licenseCode}}
设备额度：{{seatLimit}}
状态：{{status}}

管理设备：{{portalUrl}}
```

---

## 22. 隐私要求

### 22.1 授权校验允许收集

```text
购买邮箱
license code hash
installIdHash
devicePublicKey
deviceLabel
platform
osVersion
appVersion
activationId
激活时间
最近刷新时间
license 事件类型
IP hash
User-Agent hash
```

### 22.2 匿名统计允许收集

```text
app 启动
功能入口点击
导入次数
导出次数
搜索次数
错误码
崩溃类型
appVersion
osVersion
licenseState
```

### 22.3 绝对禁止收集

```text
Prompt 正文
Prompt 标题
标签名
项目名
文件名
本地路径
图片内容
视频内容
API Key
剪贴板内容
用户模型配置中的密钥
聊天内容
```

### 22.4 UI 告知

激活页必须展示：

```text
授权校验不会上传你的 Prompt、文件、图片、API Key 或本地路径。
```

设置页提供：

```text
[ ] 发送匿名使用统计，帮助改进 PromptStudio
```

授权校验是软件激活必要能力，不提供关闭开关。匿名统计必须可以关闭。

---

## 23. 安全要求

### 23.1 客户端

1. device private key 存 Keychain，使用 ThisDeviceOnly。
2. license certificate 存 Keychain。
3. 不在 UserDefaults 保存 `isPro`。
4. 所有授权判断通过 LicenseManager。
5. 验签失败不能继续 Pro。
6. 刷新失败不能立即降级，除非本地证书已超过 graceUntil。
7. 证书过期或撤销不能删除用户数据。

### 23.2 服务端

1. license code 校验使用 HMAC hash。
2. license code 可用 AES-GCM 加密保存，用于找回邮件。
3. OTP 保存 hash，不保存明文。
4. Portal session token 保存 hash，不保存明文。
5. 所有 API 做 rate limit。
6. 所有敏感字段日志脱敏。
7. 证书签名 private key 只能来自环境变量或密钥管理服务。
8. 管理 API/CLI 必须需要 ADMIN_TOKEN 或本地安全环境。
9. 邮箱枚举场景统一返回 ok。
10. 设备列表只返回隐私安全字段。

### 23.3 风险接受

本系统接受以下权衡：

```text
1. 已签发的离线证书在 expiresAt/graceUntil 前无法强制实时撤销。
2. 高级逆向者仍可能 patch 客户端。
3. 重装系统可能导致设备身份变化，用户可通过 portal 自助解绑。
4. deviceLabel 不是强身份，只用于用户识别设备。
```

---

## 24. 测试计划

### 24.1 后端单元测试

必须覆盖：

1. normalizeLicenseCode。
2. license code 生成长度和字符集。
3. codeHash 相同输入一致，不同输入不同。
4. emailHash normalize。
5. AES-GCM 加解密。
6. Ed25519 证书签名和验签。
7. OTP hash 和过期。
8. rate limit 规则。
9. issueCertificate 日期计算。
10. active device count 只统计 active。

### 24.2 后端集成测试

必须覆盖：

1. 创建 license。
2. 使用正确邮箱和 code 激活成功。
3. 错误邮箱或 code 激活失败。
4. 同一设备重复激活不重复占 seat。
5. 第二台设备激活成功。
6. 第三台设备返回 SEAT_LIMIT_EXCEEDED。
7. 设备停用后第三台可激活。
8. refunded license 不能激活和刷新。
9. revoked license 不能激活和刷新。
10. refresh challenge 只能使用一次。
11. refresh challenge 过期失败。
12. 错误 device signature 刷新失败。
13. portal 邮箱验证码登录。
14. portal 解绑设备。
15. recover 对不存在邮箱也返回 ok。

### 24.3 客户端单元测试

必须覆盖：

1. 证书解析成功。
2. 证书签名错误时失败。
3. activationId mismatch 时 Limited。
4. now <= expiresAt 为 proActive。
5. expiresAt < now <= graceUntil 为 Grace。
6. now > graceUntil 为 Limited。
7. 无证书时创建 Trial。
8. Trial 30 天内 active。
9. Trial 超过 30 天 expired。
10. FeatureGate 在 Trial/Pro/Grace/Limited 下返回正确结果。
11. refresh 网络失败时不错误降级。
12. Keychain 存取失败时展示可理解错误。

### 24.4 客户端手工测试

1. 新安装打开 app，进入 30 天试用。
2. 激活页输入错误 code，看到错误提示。
3. 输入正确 code，激活成功。
4. 退出重开 app，离线也显示 Pro。
5. 修改服务端为 revoked，客户端联网刷新后变 Limited。
6. Limited 状态下仍可打开、搜索、复制、导出已有数据。
7. Limited 状态下创建/批量导入/AI 辅助被限制。
8. app 内停用当前设备后，server seat 释放。
9. 网页 portal 解绑旧设备后，新设备可激活。
10. 匿名统计关闭后不再发送 telemetry。

---

## 25. 验收标准

功能验收：

```text
1. 用户可以无登录试用 30 天。
2. 用户可以用购买邮箱 + 激活码激活 Pro。
3. 一个 license 默认最多激活 2 台设备。
4. 同一设备重复激活不重复占用设备位。
5. 第三台设备激活时收到明确设备满提示。
6. 用户可以停用当前设备。
7. 用户可以通过网页邮箱验证码解绑旧设备。
8. 激活成功后离线 30 天内 Pro 可用。
9. 证书过期后 14 天宽限期 Pro 可用并提示刷新。
10. 宽限期结束后进入 Limited，但已有数据可打开、搜索、复制、导出。
11. 后台可以创建、撤销、退款、加购设备位、重置激活码。
12. 找回激活码不会暴露邮箱是否存在。
13. 所有敏感字段不出现在日志中。
14. 客户端不依赖可篡改的 isPro 字段。
15. 服务端签名证书可被客户端离线验签。
```

隐私验收：

```text
1. 激活请求不包含 Prompt 正文、标题、标签、本地路径、文件名、API Key。
2. telemetry 请求不包含用户内容。
3. 匿名统计可关闭。
4. 设备列表不展示硬件序列号、用户名、本地路径、IP。
```

安全验收：

```text
1. license code 不明文存储为校验依据。
2. OTP 不明文存储。
3. portal session token 不明文存储。
4. device private key 存 Keychain。
5. refresh 必须经过 challenge + device private key 签名。
6. refunded/revoked license 不能刷新新证书。
7. 设备数上限在服务端强校验。
```

---

## 26. 发布与运维

### 26.1 发布前检查

1. 生成生产 Ed25519 signing key。
2. 客户端内置生产 public key 和 key id。
3. 后端配置 production private key。
4. 数据库迁移完成。
5. SMTP 配置完成。
6. License Portal HTTPS 可访问。
7. 日志脱敏验证完成。
8. Rate limit 开启。
9. 备份策略开启。
10. 手动创建一枚测试 license，完整跑通激活、刷新、解绑、找回。

### 26.2 客服 Runbook

#### 用户说激活码无效

```text
1. 让用户复制购买邮件中的购买邮箱和激活码。
2. 后台按 emailHash 查询 license。
3. 查看 license.status。
4. 查看 license_events activation_failed 错误原因。
5. 不在聊天中要求用户发送完整激活码；最多发送前缀和后 4 位。
```

#### 用户设备满了

```text
1. 引导用户打开 License Portal 自助解绑。
2. 无法操作时，客服后台手动 deactive 某个 activation。
```

#### 用户退款

```text
1. 标记 order.status = refunded。
2. 标记 license.status = refunded。
3. 后续 refresh 返回 LICENSE_REFUNDED。
```

#### 激活码泄露

```text
1. 执行 rotate-code。
2. 新 code 发送到购买邮箱。
3. 视情况撤销异常 activations。
4. 保留正常用户设备。
```

---

## 27. Codex 开发任务拆分

按顺序实现，不要跳步。

### Task 1：后端基础结构

1. 新增 license server 模块或服务。
2. 配置环境变量读取。
3. 配置数据库连接。
4. 添加数据表 migration。
5. 添加统一响应格式和错误处理中间件。
6. 添加日志脱敏中间件。

### Task 2：后端 crypto utilities

1. normalizeEmail。
2. normalizeLicenseCode。
3. generateLicenseCode。
4. HMAC hash。
5. AES-256-GCM encrypt/decrypt。
6. Ed25519 sign/verify。
7. base64url helpers。
8. canonical JSON。

### Task 3：Admin CLI

1. license:create。
2. license:add-seats。
3. license:revoke。
4. license:refund。
5. license:rotate-code。
6. CLI 输出和日志脱敏。

### Task 4：Public license API

1. POST /v1/licenses/activate。
2. POST /v1/licenses/refresh/challenge。
3. POST /v1/licenses/refresh。
4. POST /v1/licenses/deactivate。
5. POST /v1/licenses/recover。
6. 事件日志。
7. 限频。

### Task 5：Portal API 和网页

1. POST /v1/auth/email-otp/send。
2. POST /v1/auth/email-otp/verify。
3. GET /v1/portal/licenses。
4. GET /v1/portal/licenses/:licenseId/devices。
5. POST /v1/portal/licenses/:licenseId/activations/:activationId/deactivate。
6. `/license` 网页。
7. 邮件模板。

### Task 6：客户端授权核心

1. LicenseState。
2. Entitlement。
3. LicenseCertificate。
4. LicenseCertificateVerifier。
5. KeychainLicenseStore。
6. DeviceIdentityManager。
7. TrialManager。
8. LicenseAPIClient。
9. LicenseManager。
10. FeatureGate。

### Task 7：客户端 UI

1. LicenseSettingsView。
2. ActivationView。
3. 激活成功 UI。
4. Grace 提示。
5. Limited 提示。
6. 管理设备入口打开 Portal URL。
7. 匿名统计开关。

### Task 8：功能接入

1. 创建/编辑 Prompt 前检查 `pro_create_edit` 或业务对应 entitlement。
2. 批量导入前检查 `pro_batch_import`。
3. AI 辅助前检查 `pro_ai_assist`。
4. 高级搜索前检查 `pro_advanced_search`。
5. 高级导出前检查 `pro_export_all_formats`。
6. 基础打开、搜索、复制、基础导出在所有状态下可用。

### Task 9：测试

1. 后端单元测试。
2. 后端集成测试。
3. 客户端单元测试。
4. 手工 E2E 测试清单。
5. 生成一枚 dev license seed。

### Task 10：文档和配置

1. README 添加本地启动 license server 的步骤。
2. README 添加如何生成 dev signing key。
3. README 添加如何创建测试 license。
4. README 添加生产部署 checklist。
5. 隐私说明文案进入 app。

---

## 28. 本地开发建议

### 28.1 生成 Ed25519 key

提供脚本：

```bash
pnpm license:keys:generate
```

输出：

```text
LICENSE_SIGNING_PRIVATE_KEY_B64=...
LICENSE_SIGNING_PUBLIC_KEY_B64=...
LICENSE_SIGNING_KEY_ID=license_signing_key_dev_01
```

### 28.2 创建测试 license

```bash
pnpm license:create --email test@example.com --plan pro_lifetime --seats 2 --provider manual --order-id dev_order_001
```

### 28.3 客户端 dev 配置

```text
LICENSE_SERVER_BASE_URL=http://localhost:8787
LICENSE_PUBLIC_KEY_ID=license_signing_key_dev_01
LICENSE_PUBLIC_KEY_B64=...
```

---

## 29. UI 文案总表

| 场景 | 文案 |
|---|---|
| 激活成功 | PromptStudio Pro 已激活。 |
| 邮箱或激活码错误 | 邮箱或激活码不匹配，请检查购买邮件。 |
| 设备数已满 | 该激活码已达到设备上限，请解绑旧设备或加购设备位。 |
| 已退款 | 该激活码当前不可用。 |
| 已撤销 | 该激活码已被撤销，如有疑问请联系支持。 |
| 网络失败 | 无法连接授权服务器，请检查网络或代理设置。 |
| 服务异常 | 授权服务暂时不可用，请稍后再试。 |
| Grace | PromptStudio Pro 需要联网刷新，你仍可继续使用 Pro 功能。 |
| Limited | Pro 功能当前不可用，但你仍可以打开、搜索、复制和导出已有数据。 |
| 停用确认 | 停用后，此设备将不再占用激活名额。你的本地数据不会被删除。 |
| 找回激活码 | 如果该邮箱存在购买记录，我们会发送激活信息。 |
| 隐私说明 | 授权校验不会上传你的 Prompt、文件、图片、API Key 或本地路径。 |

---

## 30. 最终实现原则

PromptStudio 的授权系统要做到：

```text
对购买用户：简单、透明、可离线、可换机、不折腾。
对开发者：能控设备数、能处理退款、能找回、能撤销、能加购、可审计。
对隐私：只校验授权，不上传用户内容。
对安全：服务端签名证书 + 设备私钥刷新，避免本地状态被简单篡改。
```

最终一句话方案：

```text
PromptStudio 使用「30 天全功能试用 + 购买邮箱和激活码激活 + 默认 2 台设备 + 设备密钥 + 服务端签名授权证书 + 30 天有效期 + 14 天宽限期 + 自助设备管理网页」作为 v1 激活授权系统。
```
