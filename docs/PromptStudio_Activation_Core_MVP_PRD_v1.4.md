# PromptStudio 激活授权系统 PRD v1.4

> **文档类型**：产品需求文档 + 技术实现规格 + Codex 开发执行文档  
> **版本**：v1.4 / Phase 1 Activation Core MVP / ActivateProofNonce Consumption Fix  
> **目标读者**：Codex、PromptStudio 开发者、后端开发者、macOS 客户端开发者  
> **核心目标**：Codex 只阅读本文档，即可在一个开发上下文内完成 PromptStudio 激活授权系统的 Phase 1 开发、联调、测试与验收。  
> **范围说明**：本文档以 Phase 1 可落地为最高优先级。后续 Portal、telemetry、支付 webhook、完整风控作为 Phase 2+ 规划，不阻塞第一版上线。

---

## 0. Codex 必读总指令

Codex 开始开发前，必须完整阅读本文件，并按下面的约束执行。

### 0.1 本轮只实现 Phase 1：Activation Core MVP

本轮必须完成：

1. 在当前 repo 根目录新增 `license-server/` 独立后端服务。
2. `license-server` 使用 **TypeScript + Fastify + PostgreSQL + Prisma**。
3. 实现 Admin CLI 创建和管理 license。
4. 实现激活码生成、归一化、哈希、脱敏显示。
5. 实现服务端激活、刷新 challenge、刷新授权证书、当前设备停用、recover 安全占位。
6. 实现服务端签名 license certificate。
7. macOS 客户端实现 Keychain 存储、设备身份、设备密钥、授权证书离线验签、30 天试用、30 天证书 + 14 天宽限期。
8. macOS 客户端实现 License 设置页、激活弹窗、当前设备停用、授权状态提示。
9. 实现统一 `FeatureGate`，并接入 PromptStudio 现有核心功能。
10. 授权无效、试用过期、退款撤销或离线宽限期结束时，**不得锁死、删除、遮挡用户已有数据**。

### 0.2 本轮明确不做

Phase 1 不实现：

1. 完整 License Portal 网页。
2. 邮箱 OTP 登录 Portal。
3. 用户远程解绑旧设备网页。
4. 匿名 telemetry。
5. 支付平台 webhook。
6. 加购设备位支付页面。
7. 复杂 risk score、跨国家/IP 异常判断、人工审核后台。
8. 账号密码系统。
9. 云同步。

这些功能可预留数据库字段和 TODO，但不得为了实现它们影响 Phase 1 验收。

### 0.3 硬性安全和隐私规则

必须遵守：

1. 不上传 Prompt 正文。
2. 不上传 Prompt 标题。
3. 不上传标签名、集合名、文件名、本地路径。
4. 不上传图片、视频、附件内容。
5. 不上传 API Key。
6. 不上传剪贴板内容。
7. 不采集 Mac 序列号、网卡 MAC 地址、硬盘序列号、本地用户名。
8. 不把 license code、device private key、signing private key、pepper、token、OTP 写入日志。
9. 客户端不能内置可生成 license 的逻辑。
10. 客户端不能内置服务端签名私钥。
11. 客户端不能直接访问数据库。
12. 业务代码不得使用散落的 `isPro` 布尔判断，必须通过统一 `FeatureGate`。

### 0.4 v1.4 实施前必须修复的规格风险，优先级高于后文旧描述

Codex 必须先按本节修正实现规格，再进入编码。本节内容是 v1.4 对 v1.3/v1.2 的覆盖性修订；如果后文存在旧命名或旧流程，以本节和对应章节的 v1.4 修订为准。

1. **Ed25519 key 格式必须写死，不允许两端自由选择。**
   - 服务端签名私钥环境变量使用 `LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64`。内容必须是 **Ed25519 PKCS8 DER 的标准 base64**。
   - 客户端内置验签公钥使用 **Ed25519 raw public key 32 bytes 的 base64url**。
   - 服务端测试可额外使用 SPKI DER base64 public key fixture，但客户端不得依赖 SPKI。
   - Node、Swift 两端必须使用同一组 dev fixture 测试同一张 license certificate。

2. **activate API 必须包含首次激活 device proof。**
   - activate 请求不能只提交 `devicePublicKey`。
   - 客户端必须用刚生成的 device private key 对固定格式 `PromptStudio-Activate-Proof-v1` message 签名。
   - 服务端必须先验签，证明客户端确实持有该 `devicePublicKey` 对应的 private key，然后才允许绑定 activation。

3. **Prisma 唯一约束不能阻塞同一安装的 keychain 修复场景。**
   - 不得在 Prisma schema 中使用 `@@unique([licenseId, installIdHash])` 作为唯一约束。
   - 可以用 Postgres partial unique index 表达“同一个 license + installIdHash 同时只能有一个 active activation”。
   - 如果同一安装的 device key 丢失或重建，服务端应在事务内把旧 active activation 标记为 `stale`，再创建新的 active activation。

4. **Phase 1 的 recover 是安全占位，不是真邮件找回。**
   - UI 可以保留“找回激活码”按钮。
   - 但点击后的文案必须明确：“已收到请求；Phase 1 暂不会自动发送邮件；请使用购买邮箱联系支持”。
   - 不得展示“请查收邮件”之类会让用户误以为已经发送邮件的文案。

5. **FeatureGate 接入必须先做现有代码入口清单。**
   - Codex 必须先扫描现有 PromptStudio 代码，生成 `docs/license_feature_gate_inventory.md`。
   - 每个需要 gating 的功能必须列出 UI 入口、菜单/快捷键入口、服务层入口和接入状态。
   - Phase 1 不要求凭空实现不存在的功能，但现有的写入、高级、AI、导入、导出入口必须在 UI 层和服务层同时接入，避免只挡按钮而漏掉服务方法。

6. **ActivateProofNonce 只能在 activate proof 验签成功后消费。**
   - 服务端不得在 JSON schema 校验、时间窗口校验、nonce 未使用校验或签名验签失败阶段把 nonce 标记为 consumed。
   - 签名失败的请求不得消费 nonce，避免恶意请求用同一个 nonce 把正常激活卡掉。
   - 正确流程是：先重建 proof message 并验签；验签成功后，在数据库事务中用唯一插入或行锁消费 nonce；消费成功后才继续创建/更新 activation。
   - 如果消费 nonce 时发生唯一冲突，返回 `ACTIVATE_PROOF_REPLAYED` 或 `INVALID_ACTIVATE_PROOF`，不得继续激活。

---

## 0.5 v1.4 相对 v1.3 的新增修订

v1.4 只新增一个实现级关键约束：**`ActivateProofNonce` 的消费必须发生在 activate proof 验签成功之后。**

原因是：如果服务端在验签前就把 nonce 标记为 consumed，攻击者可以构造无效请求，使用与正常客户端相同的 `clientNonce` 提前占坑，导致正常激活请求被错误拒绝。

实现上必须遵循：

```text
签名失败 → 不消费 nonce
签名成功 → 数据库事务内原子消费 nonce
nonce 唯一约束冲突 → 判定为成功 proof 重放
```

---

## 1. 背景和问题

PromptStudio 是一款 macOS 本地软件，用于管理、组织、复用 Prompt 和 AI 工作流。用户购买软件后，开发者会通过邮件发送激活码。用户在 PromptStudio 中输入购买邮箱和激活码后，解锁 Pro 功能。

PromptStudio 的授权体验参考 Eagle 类本地软件：

```text
一次性购买
默认 2 台设备
可解绑换机
试用期后激活
本地数据不上传
短期离线可继续使用
```

但 PromptStudio 不能只做一个简单 `isPro = true` 本地开关，因为这样会导致：

1. 本地状态容易被篡改。
2. 激活码容易被多人共享。
3. 换机、重装、丢设备时没有设备管理能力。
4. 退款、撤销、激活码泄露后无法控制。
5. 离线体验和安全撤销之间没有明确平衡。

因此，PromptStudio 需要一套轻量但完整的授权系统：

```text
购买邮箱 + 激活码
+ 设备身份 installId
+ 设备密钥对 deviceKeyPair
+ 服务端签名授权证书 license certificate
+ 客户端离线验签
+ 周期刷新
+ 30 天试用
+ 30 天证书有效期
+ 14 天宽限期
+ FeatureGate 控制 Pro 功能
```

---

## 2. 最终定案

### 2.1 不一次性实现完整授权产品

完整授权产品会包含 Portal、邮箱验证码、支付 webhook、完整风控、客服后台、telemetry、加购设备位等。这些功能正确但范围太大。

本轮只做 Phase 1：Activation Core MVP。

目标是：

```text
真实用户可以购买后激活
真实客户端可以离线使用
开发者可以生成 license 和处理基础客服问题
核心 Pro 功能可以被正确 gating
用户数据永远不被授权系统绑架
```

### 2.2 后端放在当前 repo，但作为独立服务

当前 PromptStudio 仓库主要是 Swift Package / macOS app。为了让 Codex 在一个窗口里完成客户端和后端联调，Phase 1 在当前 repo 根目录新增：

```text
license-server/
```

但它必须是独立部署单元：

```text
PromptStudio macOS app  <-- HTTPS -->  license-server  <--->  PostgreSQL
```

后续需要独立部署或拆仓时，只移动 `license-server/` 目录。

### 2.3 Pro Gate 采用“试用/Pro/Grace 全功能，过期后只读安全模式”

PromptStudio v1 不做复杂 Free 版。采用：

```text
30 天全功能试用
+ Pro 一次性买断
+ 授权异常/过期后 Limited 只读安全模式
```

Limited 状态下必须允许：

```text
打开本地库
查看已有 Prompt
复制 Prompt
基础关键词搜索
基础导出 JSON 或 Markdown
删除本地数据
进入 License 设置页
输入激活码恢复授权
```

Limited 状态下禁止：

```text
新建 Prompt
编辑 Prompt
复制为新 Prompt
标签/集合管理
模板管理
自定义变量
单个导入
批量导入
高级搜索
AI 辅助
高级导出
自动化/批处理
```

核心原则：

```text
商业功能可以暂停，但用户数据不能被绑架。
```

---

## 3. Phase 规划

### 3.1 Phase 1：Activation Core MVP，本轮必须完成

目标：跑通购买后激活、设备限制、离线证书、试用、宽限期、FeatureGate。

后端必须完成：

1. `license-server/` 独立服务。
2. Fastify API。
3. PostgreSQL + Prisma schema。
4. 本地 `docker-compose.yml`。
5. `.env.example`。
6. Admin CLI。
7. 激活码生成和管理。
8. 激活 API。
9. refresh challenge API。
10. refresh API。
11. 当前设备 deactivate API。
12. recover 安全占位 API。
13. 服务端签名授权证书。
14. 基础事件日志。
15. 基础限频。
16. 后端测试。

客户端必须完成：

1. `LicenseManager`。
2. `TrialManager`。
3. `DeviceIdentityManager`。
4. `KeychainLicenseStore`。
5. `LicenseCertificateVerifier`。
6. `LicenseAPIClient`。
7. `FeatureGate`。
8. `ActivationViewModel`。
9. `LicenseSettingsView`。
10. 激活弹窗。
11. 当前设备停用。
12. Grace/Limited UI 提示。
13. 现有核心功能接入 Pro Gate。
14. 客户端测试和手工 E2E 验证。

### 3.2 Phase 2：License Portal，后续实现

目标：让用户自助管理设备，减少客服工单。

Phase 2 实现：

1. 邮箱 OTP 发送。
2. 邮箱 OTP 校验。
3. Portal session。
4. `/license` 网页。
5. 用户查看 license。
6. 用户查看设备列表。
7. 用户远程解绑旧设备。
8. 找回激活码邮件。
9. Portal 操作审计。
10. Portal 限频。

### 3.3 Phase 3：Telemetry 和完整风控，后续实现

目标：在不上传用户内容的前提下改进产品和识别激活码泄露。

Phase 3 实现：

1. 匿名 telemetry 开关。
2. 功能级匿名事件。
3. license 维度解绑频率风控。
4. 激活失败风控。
5. 疑似泄露提醒邮件。
6. risk score。
7. 人工解除限制。

### 3.4 Phase 4：支付和商业扩展，后续实现

目标：接入正式购买流程。

Phase 4 实现：

1. 支付 webhook。
2. 自动创建 license。
3. 退款自动 mark refunded/revoked。
4. 加购设备位 checkout。
5. 订单管理。
6. 发票和购买邮件。
7. 团队、教育、订阅 license 预留。

---

## 4. 用户故事

### 4.1 新用户首次安装并试用

用户首次打开 PromptStudio，不需要登录，自动获得 30 天全功能试用。

UI 显示：

```text
PromptStudio Pro 试用中 · 剩余 30 天
[输入激活码] [购买 Pro]
```

试用期间：

```text
新建、编辑、导入、AI 辅助、高级搜索、高级导出等 Pro 功能全部可用。
```

试用结束后：

```text
进入 Trial Expired / Limited 类状态，只保留 Base 安全能力。
```

### 4.2 已购买用户激活第一台设备

用户收到购买邮件：

```text
购买邮箱：user@example.com
激活码：PS-XXXX-XXXX-XXXX-XXXX-XXXX
```

用户进入：

```text
Settings → License → 输入激活码
```

输入购买邮箱和激活码。客户端生成设备身份并调用后端激活 API。

成功后 UI 显示：

```text
PromptStudio Pro 已激活
授权类型：Pro Lifetime
当前设备：MacBook Pro - macOS 15
设备额度：1 / 2
```

### 4.3 同一激活码激活第二台设备

用户在第二台 Mac 上输入同一购买邮箱和激活码。服务端发现当前 active activations 数量为 1，小于 seatLimit 2，允许激活。

成功后显示：

```text
设备额度：2 / 2
```

### 4.4 第三台设备尝试激活

第三台设备输入同一购买邮箱和激活码。

服务端返回：

```text
SEAT_LIMIT_EXCEEDED
```

客户端显示：

```text
该激活码已达到 2 台设备上限。

已激活设备：
1. MacBook Pro - macOS 15，最近使用：2026-06-10
2. Mac mini - macOS 14，最近使用：2026-06-01

[停用当前设备后重试] [联系支持]
```

Phase 1 不做 Portal 解绑旧设备；旧设备丢失时由开发者使用 Admin CLI 处理。

### 4.5 当前设备停用

用户在当前已激活设备中点击：

```text
Settings → License → 停用当前设备
```

客户端先请求 refresh challenge，然后用 device private key 签名，再调用 deactivate API。

成功后：

1. 服务端把该 activation 标记为 `deactivated`。
2. 客户端删除本地 license certificate 和 activationId。
3. 客户端不得删除本地资料库。
4. 该 seat 被释放。

### 4.6 离线启动

用户激活后断网，重新打开 PromptStudio。

客户端读取 Keychain 中的 license certificate，使用内置 public key 离线验签。

判断：

```text
当前时间 <= expiresAt：Pro Active
expiresAt < 当前时间 <= graceUntil：Grace
当前时间 > graceUntil：Limited
```

### 4.7 授权撤销或退款

后台把 license 标记为 `revoked` 或 `refunded`。客户端下一次 refresh 时收到 revoked 状态或无法获得新证书，进入 Limited。

注意：

```text
已经签发的离线证书在 expiresAt + graceUntil 范围内仍可能生效。
这是本地软件离线体验和撤销能力之间的有意权衡。
```

---

## 5. 授权状态模型

客户端统一使用 `LicenseState`。业务代码不得自行组合状态。

```swift
enum LicenseState: Equatable {
    case trialActive(daysRemaining: Int)
    case trialExpired
    case proActive(certificate: LicenseCertificate)
    case grace(certificate: LicenseCertificate, daysRemaining: Int)
    case limited(reason: LimitedReason)
    case revoked(reason: String?)
}

enum LimitedReason: Equatable {
    case noLicense
    case trialExpired
    case certificateExpired
    case invalidCertificate
    case deviceMismatch
    case revoked
    case refreshRequired
    case clockInvalid
}
```

状态含义：

| 状态 | 触发条件 | 允许能力 | UI 提示 |
|---|---|---|---|
| `trialActive` | 首次安装 30 天内，无 Pro 证书 | 全部 Pro 功能 | 显示剩余试用天数 |
| `trialExpired` | 试用超过 30 天，无 Pro 证书 | Base 安全能力 | 提示试用结束 |
| `proActive` | 证书验签成功且未过期 | 证书包含的 Pro 功能 | 显示已激活 |
| `grace` | 证书过期但在宽限期 | 证书包含的 Pro 功能 | 提示联网刷新 |
| `limited` | 无有效授权或宽限结束 | Base 安全能力 | 提示 Pro 功能暂停 |
| `revoked` | 刷新时得知授权撤销/退款 | Base 安全能力 | 提示授权不可用 |

客户端启动时状态解析顺序：

```text
1. 从 Keychain 读取 license certificate。
2. 如果证书存在，先验证签名、audience、bundleId、activationId、device key thumbprint。
3. 证书有效且未过期：proActive。
4. 证书过期但仍在 graceUntil 内：grace。
5. 证书无效或超过 grace：继续检查 trial。
6. trial 未过期：trialActive。
7. trial 已过期：trialExpired / limited。
```

建议实现为：

```swift
final class LicenseManager: ObservableObject {
    @Published private(set) var state: LicenseState

    func loadStateOnLaunch()
    func activate(email: String, licenseCode: String) async throws
    func refreshIfNeeded() async
    func forceRefresh() async throws
    func deactivateCurrentDevice() async throws
}
```

---

## 6. FeatureGate 定案

### 6.1 原则

PromptStudio 不允许业务代码直接判断：

```swift
if licenseManager.isPro { ... }
```

必须统一使用：

```swift
featureGate.evaluate(.proCreatePrompt)
featureGate.require(.proCreatePrompt)
try featureGate.assertAllowed(.proCreatePrompt)
```

同一个功能必须在至少两个层面拦截：

1. UI 层：按钮、菜单、快捷键、右键入口。
2. 服务层：真正执行 create/edit/import/export/ai 的方法。

### 6.2 FeatureKey

```swift
enum FeatureKey: String, CaseIterable, Codable {
    // Base：任何授权状态都允许，保障用户数据安全
    case baseOpenLibrary = "base.open_library"
    case baseViewPrompt = "base.view_prompt"
    case baseCopyPrompt = "base.copy_prompt"
    case baseBasicSearch = "base.basic_search"
    case baseBasicExport = "base.basic_export"
    case baseDeleteLocalData = "base.delete_local_data"
    case baseLicenseSettings = "base.license_settings"

    // Pro：Trial / Pro / Grace 允许，Limited / Revoked / TrialExpired 禁止
    case proCreatePrompt = "pro.create_prompt"
    case proEditPrompt = "pro.edit_prompt"
    case proDuplicatePrompt = "pro.duplicate_prompt"
    case proManageTags = "pro.manage_tags"
    case proManageCollections = "pro.manage_collections"
    case proTemplates = "pro.templates"
    case proCustomVariables = "pro.custom_variables"
    case proSingleImport = "pro.single_import"
    case proBatchImport = "pro.batch_import"
    case proAdvancedSearch = "pro.advanced_search"
    case proAIAssist = "pro.ai_assist"
    case proAdvancedExport = "pro.advanced_export"
    case proAutomation = "pro.automation"
}
```

### 6.3 Base 能力

任何状态都必须允许：

| 功能 | FeatureKey | 说明 |
|---|---|---|
| 打开本地资料库 | `base.open_library` | 不得阻止用户进入自己的资料库。 |
| 查看已有 Prompt | `base.view_prompt` | 不得遮挡已有内容。 |
| 复制 Prompt 内容 | `base.copy_prompt` | 用户必须能取回自己的内容。 |
| 基础关键词搜索 | `base.basic_search` | 用于找到已有数据。 |
| 基础导出 | `base.basic_export` | 至少支持 JSON 或 Markdown 全量导出。 |
| 删除本地数据 | `base.delete_local_data` | 用户有权删除自己的本地数据。 |
| 打开 License 设置 | `base.license_settings` | 用户必须能激活或恢复授权。 |

### 6.4 Pro 能力

Trial Active、Pro Active、Grace 允许；Trial Expired、Limited、Revoked 禁止：

| 业务动作 | FeatureKey | 必须拦截的位置 |
|---|---|---|
| 新建 Prompt | `pro.create_prompt` | 新建按钮、菜单、快捷键、命令面板、服务层 create 方法 |
| 编辑 Prompt 正文/标题 | `pro.edit_prompt` | 编辑器进入编辑、保存动作、快捷键、服务层 update 方法 |
| 复制为新 Prompt | `pro.duplicate_prompt` | 右键菜单、快捷键、服务层 duplicate 方法 |
| 管理标签 | `pro.manage_tags` | 标签新增、重命名、删除、批量打标、拖拽标签 |
| 管理集合/文件夹 | `pro.manage_collections` | 新建集合、移动 Prompt、集合排序、删除集合 |
| 模板管理 | `pro.templates` | 新建模板、保存模板、应用高级模板 |
| 自定义变量 | `pro.custom_variables` | 变量创建、编辑、批处理 |
| 单个导入 | `pro.single_import` | 菜单导入、拖拽导入、服务层 import 方法 |
| 批量导入 | `pro.batch_import` | 批量导入向导、文件夹导入、批量解析 |
| 高级搜索 | `pro.advanced_search` | 组合过滤器、保存搜索、语义搜索、正则、高级语法 |
| AI 辅助 | `pro.ai_assist` | 优化、生成、改写、评分、模型调用 |
| 高级导出 | `pro.advanced_export` | PDF、模板化 Markdown、自定义字段、批量格式转换 |
| 自动化/批处理 | `pro.automation` | 批量清洗、批量改写、动作链、批量执行 |

### 6.5 搜索边界

```text
base.basic_search：本地关键词搜索，所有状态允许。
pro.advanced_search：组合条件、保存搜索、语义搜索、正则/高级语法，只有 Pro/Trial/Grace 允许。
```

### 6.6 导出边界

```text
base.basic_export：导出已有全部数据到 JSON 或 Markdown，所有状态允许。
pro.advanced_export：PDF、模板导出、字段映射、格式美化、批量转换，只有 Pro/Trial/Grace 允许。
```

基础导出是用户数据安全出口，不是商业功能，不能放进 Pro。

### 6.7 AI 功能边界

只要动作由 PromptStudio 内部发起模型调用、生成、优化、改写、评分、批处理，都属于：

```text
pro.ai_assist
```

即使用户使用自己的 API Key，也仍然是 Pro 功能。商业价值来自 PromptStudio 的工作流能力，不是 API Key 成本。

### 6.8 FeatureDecision

`FeatureGate` 不应只返回 Bool，必须返回可解释结果，方便 UI 统一提示。

```swift
struct FeatureDecision: Equatable {
    let allowed: Bool
    let feature: FeatureKey
    let reason: FeatureDeniedReason?
    let title: String?
    let message: String?
    let primaryAction: UpgradeAction?
}

enum FeatureDeniedReason: Equatable {
    case trialExpired
    case licenseRequired
    case licenseExpired
    case licenseRevoked
    case featureNotIncluded
}

enum UpgradeAction: Equatable {
    case activate
    case buyPro
    case refreshLicense
    case contactSupport
}
```

示例调用：

```swift
let decision = featureGate.evaluate(.proBatchImport)
if !decision.allowed {
    upgradePresenter.present(decision)
    return
}
```

---

## 7. 总体架构

### 7.1 架构图

```text
┌───────────────────────────────────────────────┐
│ PromptStudio macOS App                         │
│                                               │
│  LicenseManager                               │
│  TrialManager                                 │
│  DeviceIdentityManager                        │
│  KeychainLicenseStore                         │
│  LicenseCertificateVerifier                   │
│  LicenseAPIClient                             │
│  FeatureGate                                  │
└───────────────────────┬───────────────────────┘
                        │ HTTPS JSON API
                        ▼
┌───────────────────────────────────────────────┐
│ license-server                                │
│ TypeScript + Fastify                          │
│                                               │
│  LicenseService                               │
│  ActivationService                            │
│  CertificateService                           │
│  DeviceProofService                           │
│  RateLimitService                             │
│  AuditEventService                            │
│  Admin CLI                                    │
└───────────────────────┬───────────────────────┘
                        │ Prisma
                        ▼
┌───────────────────────────────────────────────┐
│ PostgreSQL                                     │
│ customers / licenses / activations             │
│ refresh_challenges / license_events            │
│ license_certificates                           │
└───────────────────────────────────────────────┘
```

### 7.2 设备身份

设备身份由三部分组成：

```text
installId + deviceKeyPair + activationId
```

- `installId`：客户端首次启动或首次激活时生成的随机 ID，存 Keychain。服务端只保存 hash。
- `deviceKeyPair`：客户端生成的设备签名密钥对，private key 存 Keychain，public key 发给服务端。
- `activationId`：服务端激活成功后创建，标识某 license 在某设备上的激活记录。

不得使用：

```text
Mac 序列号
网卡 MAC 地址
硬盘序列号
本地用户名
真实路径
```

### 7.3 授权证书

服务端签发 license certificate。客户端内置 public key 离线验签。

v1.3 起，签名 key 格式必须固定：

```text
服务端私钥：LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64
格式：Ed25519 PKCS8 DER 的标准 base64
用途：只用于 license-server 签发证书

客户端公钥：内置 kid -> rawPublicKeyBase64url map
格式：Ed25519 raw public key 32 bytes 的 base64url
用途：只用于 macOS 客户端离线验签
```

客户端不得内置 PKCS8 private key、服务端 pepper 或任何可生成 license 的 secret。

### 7.4 网络策略

```text
首次激活：必须联网
授权刷新：联网时自动后台刷新
离线使用：证书有效期内允许
证书过期：14 天宽限期
宽限结束：Limited，只保留 Base 安全能力
```

---

## 8. Repo 目录结构

Codex 应优先按现有项目目录风格落地。如果当前 repo 没有授权相关目录，按下面结构新增。

```text
repo-root/
  license-server/
    package.json
    package-lock.json 或 pnpm-lock.yaml
    tsconfig.json
    Dockerfile
    docker-compose.yml
    .env.example
    README.md
    prisma/
      schema.prisma
      migrations/
    src/
      index.ts
      app.ts
      config.ts
      routes/
        health.ts
        licenses.ts
      services/
        LicenseService.ts
        ActivationService.ts
        CertificateService.ts
        DeviceProofService.ts
        RateLimitService.ts
        AuditEventService.ts
      crypto/
        licenseCode.ts
        hash.ts
        signing.ts
        canonicalJson.ts
        base64url.ts
      db/
        prisma.ts
      cli/
        index.ts
        createLicense.ts
        listLicenses.ts
        addSeats.ts
        revokeLicense.ts
        deactivateDevice.ts
        rotateCode.ts
      tests/
        licenseCode.test.ts
        certificate.test.ts
        activate.integration.test.ts
        refresh.integration.test.ts
        deactivate.integration.test.ts

  # Swift 目录以现有项目为准，授权代码需集中存放
  Sources 或 App 目录/
    License/
      LicenseState.swift
      Entitlement.swift
      FeatureKey.swift
      FeatureGate.swift
      LicenseCertificate.swift
      LicenseCertificateVerifier.swift
      LicenseManager.swift
      LicenseAPIClient.swift
      TrialManager.swift
      DeviceIdentityManager.swift
      KeychainLicenseStore.swift
      ActivationViewModel.swift
      LicenseSettingsView.swift
      ActivationSheetView.swift
```

---

## 9. license-server 技术规格

### 9.1 技术栈

默认：

```text
Node.js 20+
TypeScript
Fastify
PostgreSQL
Prisma
Vitest 或 Jest
Zod
```

### 9.2 package scripts

`license-server/package.json` 至少提供：

```json
{
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "test": "vitest run",
    "test:watch": "vitest",
    "prisma:generate": "prisma generate",
    "prisma:migrate": "prisma migrate dev",
    "prisma:studio": "prisma studio",
    "cli": "tsx src/cli/index.ts"
  }
}
```

### 9.3 环境变量

`license-server/.env.example`：

```text
NODE_ENV=development
PORT=8787
DATABASE_URL=postgresql://promptstudio:promptstudio@localhost:5432/promptstudio_license

LICENSE_CODE_PEPPER=replace-with-random-32-bytes-base64
LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64=replace-with-ed25519-private-key-pkcs8-der-base64
LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL=replace-with-ed25519-public-key-raw-32-bytes-base64url
LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64=optional-test-only-spki-der-base64
LICENSE_SIGNING_KEY_ID=dev-key-1
LICENSE_CERTIFICATE_ISSUER=promptstudio-license-server
LICENSE_CERTIFICATE_AUDIENCE=promptstudio-macos
LICENSE_BUNDLE_ID=com.promptstudio.app
LICENSE_CERT_DAYS=30
LICENSE_GRACE_DAYS=14
LICENSE_REFRESH_AFTER_DAYS=7

RATE_LIMIT_ENABLED=true
LOG_LEVEL=info
```

生产要求：

1. `LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64` 只能在服务端环境变量或 secret manager 中，必须是 Ed25519 PKCS8 DER base64。
2. `LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL` 必须是同一私钥派生出的 Ed25519 raw 32 bytes public key base64url，用于客户端内置和测试 fixture。
3. `LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64` 只用于服务端测试或工具校验，可选，不传给客户端。
4. `LICENSE_CODE_PEPPER` 必须备份，丢失会导致旧激活码无法校验。
5. dev key 和 prod key 必须不同。
6. 生产 `.env` 不得提交。

### 9.4 docker-compose

`license-server/docker-compose.yml` 提供本地 Postgres：

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: promptstudio
      POSTGRES_PASSWORD: promptstudio
      POSTGRES_DB: promptstudio_license
    ports:
      - "5432:5432"
    volumes:
      - promptstudio_license_pg:/var/lib/postgresql/data

volumes:
  promptstudio_license_pg:
```

---

## 10. 数据模型

### 10.1 Prisma schema 参考

Codex 可按项目风格调整字段名，但语义必须一致。

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

enum LicenseStatus {
  unused
  active
  limited
  refunded
  revoked
  disabled
}

enum LicenseType {
  lifetime
  subscription
  trial
  education
  team
  beta
}

enum ActivationStatus {
  active
  deactivated
  revoked
  stale
}

enum EventSource {
  api
  cli
  system
}

model Customer {
  id          String   @id @default(cuid())
  emailHash   String   @unique
  emailMasked String
  createdAt   DateTime @default(now())
  updatedAt   DateTime @updatedAt

  licenses License[]
}

model License {
  id             String        @id @default(cuid())
  customerId     String
  customer       Customer      @relation(fields: [customerId], references: [id])

  codePrefix     String
  codeHash       String        @unique
  codeMasked     String

  plan           String        @default("pro_lifetime")
  licenseType    LicenseType   @default(lifetime)
  status         LicenseStatus @default(unused)
  seatLimit      Int           @default(2)
  majorVersion   Int           @default(1)
  updatesUntil   DateTime?

  orderProvider  String?
  orderId        String?

  createdAt      DateTime      @default(now())
  activatedAt    DateTime?
  revokedAt      DateTime?
  revokedReason  String?
  refundedAt     DateTime?
  notes          String?

  activations    Activation[]
  certificates   LicenseCertificate[]
  events         LicenseEvent[]

  @@index([customerId])
  @@index([codePrefix])
  @@index([status])
}

model Activation {
  id                   String           @id @default(cuid())
  licenseId            String
  license              License          @relation(fields: [licenseId], references: [id])

  installIdHash         String
  devicePublicKey       String
  deviceKeyThumbprint   String
  deviceLabel           String
  platform              String           @default("macos")
  osVersion             String?
  appVersion            String?
  status                ActivationStatus @default(active)

  activatedAt           DateTime         @default(now())
  lastSeenAt            DateTime?
  deactivatedAt         DateTime?
  deactivatedReason     String?
  replacedByActivationId String?

  certificates          LicenseCertificate[]
  challenges            RefreshChallenge[]
  events                LicenseEvent[]

  @@index([licenseId, installIdHash])
  @@index([licenseId, installIdHash, status])
  @@index([licenseId, status])
  @@index([deviceKeyThumbprint])
}

model ActivateProofNonce {
  id                    String   @id @default(cuid())
  nonceHash             String
  deviceKeyThumbprint   String
  expiresAt             DateTime
  consumedAt            DateTime?
  createdAt             DateTime @default(now())

  @@unique([nonceHash, deviceKeyThumbprint])
  @@index([expiresAt])
}

model RefreshChallenge {
  id           String     @id @default(cuid())
  activationId String
  activation   Activation @relation(fields: [activationId], references: [id])
  nonce        String
  expiresAt    DateTime
  consumedAt   DateTime?
  createdAt    DateTime   @default(now())

  @@index([activationId])
  @@index([expiresAt])
}

model LicenseCertificate {
  id              String     @id @default(cuid())
  licenseId       String
  license         License    @relation(fields: [licenseId], references: [id])
  activationId    String
  activation      Activation @relation(fields: [activationId], references: [id])

  kid             String
  certificateHash String
  issuedAt        DateTime
  expiresAt       DateTime
  graceUntil      DateTime
  createdAt       DateTime   @default(now())

  @@index([licenseId])
  @@index([activationId])
}

model LicenseEvent {
  id             String      @id @default(cuid())
  licenseId      String?
  license        License?    @relation(fields: [licenseId], references: [id])
  activationId   String?
  activation     Activation? @relation(fields: [activationId], references: [id])

  eventType      String
  eventSource    EventSource @default(api)
  emailHash      String?
  codePrefix     String?
  ipHash         String?
  userAgentHash  String?
  metadataJson   Json?
  createdAt      DateTime    @default(now())

  @@index([licenseId])
  @@index([activationId])
  @@index([eventType])
  @@index([createdAt])
}
```

### 10.1.1 Postgres partial unique index，必须通过 raw SQL migration 添加

Prisma schema 不能直接表达 partial unique index，因此 migration 必须额外包含以下 SQL，用来表达“同一个 license + installIdHash 同时最多只能有一个 active activation”：

```sql
CREATE UNIQUE INDEX IF NOT EXISTS activation_unique_active_install
ON "Activation" ("licenseId", "installIdHash")
WHERE "status" = 'active';
```

注意：不得用 Prisma 的 `@@unique([licenseId, installIdHash])` 替代它，因为那会阻止同一安装在 Keychain 私钥丢失/重建后重新创建 activation。

重激活事务规则：

1. 如果存在同一 `licenseId + installIdHash + status=active` 且 `deviceKeyThumbprint` 相同，视为同一设备重激活，不新占 seat，只更新 `lastSeenAt/appVersion/osVersion/deviceLabel` 并重新签发证书。
2. 如果存在同一 `licenseId + installIdHash + status=active` 但 `deviceKeyThumbprint` 不同，视为同一安装 device key 重建：先把旧 activation 标记为 `stale`，设置 `deactivatedReason = device_key_replaced` 和 `replacedByActivationId`，再创建新的 active activation。
3. 如果只有 `deactivated/stale/revoked` 旧记录，不得复用旧 activation id；创建新 activation，并按当前 active seat 数判断是否允许。
4. 所有上述变更必须在数据库事务中完成，避免并发激活绕过 seatLimit。

### 10.2 字段说明

#### Customer

- `emailHash`：归一化邮箱的 HMAC/SHA 哈希，用于匹配，不直接暴露邮箱。
- `emailMasked`：用于 CLI 和设备超限提示，例如 `u***@example.com`。

Phase 1 可以不存可解密邮箱，因为 recover 不实际发邮件。Phase 2 需要邮件发送时，可新增 `emailEncrypted`。

#### License

- `codeHash`：激活码归一化后的 HMAC，不保存明文激活码。
- `codePrefix`：用于客服查找和限频，不足以还原完整激活码。
- `codeMasked`：例如 `PS-7K4D-****-****-GV`。
- `seatLimit`：默认 2，CLI 可增加。
- `updatesUntil`：未来更新权益预留。

#### Activation

- `installIdHash`：客户端随机 installId 的 hash。
- `devicePublicKey`：设备公钥，用于 refresh/deactivate 验签。
- `deviceKeyThumbprint`：公钥指纹，证书内也会包含。算法固定为 `base64url(SHA256(rawPublicKey32Bytes))`。
- `deviceLabel`：脱敏设备标签，例如 `MacBook Pro - macOS 15`。
- `replacedByActivationId`：同一安装 device key 重建时，旧 activation 指向新 activation，便于审计和客服排查。

Activation 不使用全局唯一 `licenseId + installIdHash`。同一安装因 Keychain 丢失、系统迁移或 device key 重建需要重新激活时，服务端必须能创建新 activation。唯一 active 语义由 Postgres partial unique index 和服务端事务共同保证。

#### ActivateProofNonce

用于首次激活 proof 的 client nonce 防重放。

要求：

1. `nonceHash = HMAC_SHA256(LICENSE_CODE_PEPPER, clientNonce + ":" + deviceKeyThumbprint)` 或等效服务端 secret HMAC。
2. 同一 `nonceHash + deviceKeyThumbprint` 只能使用一次。
3. `expiresAt` 默认 `createdAt + 24h`。
4. 后端可以在 activate 请求时懒清理过期 nonce。
5. `ActivateProofNonce` 不代表服务端预先发出的 challenge；它是首次激活请求中的 client nonce 防重放记录。
6. 不得在签名验签前插入 consumed 记录或设置 `consumedAt`。签名失败、JSON schema 失败、时间窗口失败、devicePublicKey 非法等请求，均不得消费 nonce。
7. 验签成功后，服务端必须在数据库事务中消费 nonce，推荐用 `INSERT ... ON CONFLICT DO NOTHING RETURNING id` 或等效唯一插入。插入成功才允许继续 activation 创建或重激活逻辑。
8. 如果唯一插入失败，说明该 `clientNonce + deviceKeyThumbprint` 已被成功 proof 使用过，必须返回 `ACTIVATE_PROOF_REPLAYED` 或 `INVALID_ACTIVATE_PROOF`，并不得继续激活。

推荐消费时机：

```text
校验 JSON schema
→ 校验 devicePublicKey/base64url/createdAt 时间窗口
→ 计算 deviceKeyThumbprint 和 nonceHash
→ 检查是否已存在已消费 nonce，仅用于快速失败，不做写入
→ 重建 PromptStudio-Activate-Proof-v1 message
→ 验证 Ed25519 signature
→ 验签失败：返回 INVALID_ACTIVATE_PROOF，不写 ActivateProofNonce
→ 验签成功：进入数据库事务
→ 原子消费 nonce：唯一插入 nonceHash + deviceKeyThumbprint，consumedAt = now
→ 如果唯一冲突：返回 ACTIVATE_PROOF_REPLAYED，不创建 activation
→ nonce 消费成功后：继续 email/license/seat/activation 逻辑
```

这样可以避免恶意请求复用某个 `clientNonce` 但提交错误签名，提前把 nonce 标记为 consumed，导致真实客户端随后使用同一个 nonce 的合法激活请求被卡掉。

#### RefreshChallenge

一次 challenge 只能用一次，且短期有效。

建议有效期：

```text
5 分钟
```

---

## 11. 激活码设计

### 11.1 格式

推荐格式：

```text
PS-XXXX-XXXX-XXXX-XXXX-XXXX
```

示例：

```text
PS-7K4D-M9QF-2X8P-R6TA-B3HE
```

要求：

1. 至少 128-bit 随机强度。
2. 使用不易混淆字符，建议 Crockford Base32，避免 `O/0/I/1`。
3. 用户输入时允许带横杠或不带横杠。
4. 用户输入时自动转大写。
5. 服务端只保存 hash，不保存明文。
6. Admin CLI 创建时明文只输出一次。

### 11.2 归一化

```ts
function normalizeLicenseCode(input: string): string {
  return input
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}
```

### 11.3 哈希

使用 HMAC-SHA256：

```text
codeHash = HMAC_SHA256(LICENSE_CODE_PEPPER, normalizedCode)
```

不要使用普通 SHA256 直接 hash 激活码。虽然激活码随机性高，但 HMAC pepper 可以降低数据库泄露后的离线验证风险。

### 11.4 脱敏显示

示例：

```text
PS-7K4D-****-****-B3HE
```

后台日志、事件和 CLI 列表只能显示 masked code 或 prefix，不得输出完整 code。

---

## 12. 授权证书设计

### 12.1 证书格式

推荐使用 JWS-like compact 格式：

```text
base64url(headerJson).base64url(payloadJson).base64url(signature)
```

签名输入：

```text
base64url(headerJson) + "." + base64url(payloadJson)
```

签名算法：

```text
Ed25519 / EdDSA
```

Node 服务端可使用 `crypto.sign(null, data, privateKey)`。Swift 客户端应优先使用 CryptoKit 的 `Curve25519.Signing.PublicKey(rawRepresentation:)` 对 Ed25519 raw public key 进行验签。

### 12.1.1 Ed25519 key 格式，强制规范

Phase 1 必须固定以下格式，避免 Node 和 Swift 两端 key 导入方式不一致。

#### 服务端签名私钥

环境变量：

```text
LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64
```

格式：

```text
Ed25519 private key
PKCS8 DER
standard base64, not base64url
```

Node 导入方式必须等价于：

```ts
import { createPrivateKey } from "node:crypto";

const privateKey = createPrivateKey({
  key: Buffer.from(process.env.LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64!, "base64"),
  format: "der",
  type: "pkcs8"
});
```

#### 客户端验签公钥

客户端内置 public key map：

```swift
let licensePublicKeys: [String: String] = [
    "dev-key-1": "<ed25519-raw-public-key-32-bytes-base64url>"
]
```

格式：

```text
Ed25519 public key rawRepresentation
固定 32 bytes
base64url without padding
```

Swift 导入方式必须等价于：

```swift
let rawPublicKey = Data(base64URLEncoded: rawPublicKeyBase64URL)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
let isValid = publicKey.isValidSignature(signatureData, for: signingInputData)
```

#### 服务端测试用 SPKI DER public key，可选

服务端测试或 CLI 可额外生成：

```text
LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64
```

格式：

```text
Ed25519 public key
SPKI DER
standard base64
```

客户端不得依赖 SPKI DER。客户端只使用 raw 32 bytes。

#### raw public key 和 SPKI public key 转换

Ed25519 SPKI DER public key 的前缀固定为：

```text
302a300506032b6570032100
```

因此：

```text
spkiDer = hex(302a300506032b6570032100) + rawPublicKey32Bytes
rawPublicKey32Bytes = last 32 bytes of valid Ed25519 SPKI DER
```

服务端验证设备 proof 时，如果 Node crypto 需要 KeyObject，必须把客户端提交的 raw 32 bytes `devicePublicKey` 转换成 SPKI DER 后再 `createPublicKey({ format: "der", type: "spki" })`。

#### 两端共用 fixture，强制要求

Codex 必须在后端测试和 Swift 测试中使用同一组 dev fixture。建议路径：

```text
license-server/tests/fixtures/ed25519_dev_private.pkcs8.der.b64
license-server/tests/fixtures/ed25519_dev_public.spki.der.b64
license-server/tests/fixtures/ed25519_dev_public.raw.b64url
license-server/tests/fixtures/license_certificate_valid.txt

# Swift 测试不要重新生成 key，应读取或复制同一组 fixture 内容
PromptStudioTests/LicenseFixtures/ed25519_dev_public.raw.b64url
PromptStudioTests/LicenseFixtures/license_certificate_valid.txt
```

最低测试要求：

1. Node 使用 PKCS8 DER private key 签发 `license_certificate_valid.txt`。
2. Swift 使用 raw 32 bytes public key 成功验签同一个 certificate。
3. Swift 修改 payload 任意字段后验签失败。
4. Node 使用同一 raw public key 转 SPKI 后验证 device proof 成功。

### 12.2 Header

```json
{
  "typ": "PS-LICENSE-CERT",
  "alg": "EdDSA",
  "kid": "dev-key-1",
  "v": 1
}
```

### 12.3 Payload

```json
{
  "iss": "promptstudio-license-server",
  "aud": "promptstudio-macos",
  "bundleId": "com.promptstudio.app",
  "licenseId": "lic_...",
  "activationId": "act_...",
  "customerEmailHash": "...",
  "plan": "pro_lifetime",
  "licenseType": "lifetime",
  "status": "active",
  "seatLimit": 2,
  "features": [
    "pro.create_prompt",
    "pro.edit_prompt",
    "pro.duplicate_prompt",
    "pro.manage_tags",
    "pro.manage_collections",
    "pro.templates",
    "pro.custom_variables",
    "pro.single_import",
    "pro.batch_import",
    "pro.advanced_search",
    "pro.ai_assist",
    "pro.advanced_export",
    "pro.automation"
  ],
  "majorVersion": 1,
  "updatesUntil": null,
  "deviceKeyThumbprint": "...",
  "issuedAt": "2026-06-15T00:00:00.000Z",
  "refreshAfter": "2026-06-22T00:00:00.000Z",
  "expiresAt": "2026-07-15T00:00:00.000Z",
  "graceUntil": "2026-07-29T00:00:00.000Z",
  "serverTime": "2026-06-15T00:00:00.000Z"
}
```

### 12.4 客户端验签要求

客户端验证证书时必须检查：

1. JWS 结构合法。
2. `alg == EdDSA`。
3. `kid` 在内置 public key map 中存在。
4. 签名正确。
5. `iss` 正确。
6. `aud` 正确。
7. `bundleId` 匹配当前 app。
8. `activationId` 匹配 Keychain 中的 activationId。
9. `deviceKeyThumbprint` 匹配 Keychain 中 device public key 的 thumbprint。
10. 当前 app major version 在授权范围内。
11. 当前时间未超过 `graceUntil`，否则进入 Limited。

### 12.5 证书有效期

默认：

```text
expiresAt = issuedAt + 30 days
graceUntil = expiresAt + 14 days
refreshAfter = issuedAt + 7 days
```

客户端联网时，如果当前时间超过 `refreshAfter`，应后台静默刷新。

---

## 13. 设备 proof 设计

### 13.1 设备密钥

客户端首次激活前生成设备签名密钥对：

```text
devicePrivateKey：Keychain only
devicePublicKey：发送给服务端
```

强制格式：

```text
devicePrivateKey：Ed25519 private key，客户端 Keychain 保存；Phase 1 使用 CryptoKit `Curve25519.Signing.PrivateKey.rawRepresentation` 存入 Keychain，不依赖 Secure Enclave
devicePublicKey：Ed25519 raw public key 32 bytes，base64url without padding
deviceKeyThumbprint：base64url(SHA256(rawPublicKey32Bytes))
```

服务端只保存 `devicePublicKey` 和 `deviceKeyThumbprint`，不得保存 device private key。

### 13.2 activate proof，首次激活必须证明持有 device private key

v1.3 起，`POST /v1/licenses/activate` 不能只提交 `devicePublicKey`。v1.4 起，`ActivateProofNonce` 必须只在 proof 验签成功后消费。客户端必须提交 `deviceProof`，证明当前客户端确实持有与 `devicePublicKey` 对应的 private key。

#### activate proof 请求字段

activate 请求中必须包含：

```json
{
  "deviceProof": {
    "version": "PromptStudio-Activate-Proof-v1",
    "clientNonce": "base64url-16-to-32-random-bytes",
    "createdAt": "2026-06-15T15:00:00.000Z",
    "signature": "base64url-ed25519-signature"
  }
}
```

要求：

1. `clientNonce` 至少 128-bit 随机。
2. `createdAt` 必须是 UTC ISO8601。
3. 服务端只接受 `createdAt` 与服务端当前时间相差不超过 10 分钟的请求。
4. 服务端必须用 `ActivateProofNonce` 防止同一 `clientNonce + deviceKeyThumbprint` 重放。
5. 签名失败返回 `INVALID_ACTIVATE_PROOF`。

#### activate proof message 固定格式

签名 message 必须严格使用以下字段、顺序和换行符。

```text
PromptStudio-Activate-Proof-v1
emailSha256:{emailSha256}
licenseCodeSha256:{licenseCodeSha256}
installIdHash:{installIdHash}
devicePublicKey:{devicePublicKey}
bundleId:{bundleId}
appVersion:{appVersion}
osVersion:{osVersion}
clientNonce:{clientNonce}
createdAt:{createdAt}
```

拼接规则：

1. 使用 UTF-8。
2. 行与行之间使用 `\n`。
3. 末尾不追加额外空行。
4. `emailSha256 = base64url(SHA256(normalizeEmail(email)))`。
5. `licenseCodeSha256 = base64url(SHA256(normalizeLicenseCode(licenseCode)))`。
6. `installIdHash` 必须与请求 JSON 中完全一致。
7. `devicePublicKey` 必须与请求 JSON 中完全一致。
8. `bundleId` 必须与请求 JSON 中完全一致，并等于服务端允许的 `LICENSE_BUNDLE_ID`。
9. `appVersion/osVersion` 为空时使用字面值 `-`，不得省略字段。

服务端校验顺序：

```text
1. 校验 JSON schema。
2. 校验 devicePublicKey 是合法 base64url 且解码后正好 32 bytes。
3. 用 devicePublicKey 计算 deviceKeyThumbprint。
4. 校验 deviceProof.version。
5. 校验 clientNonce 长度和 createdAt 时间窗口。
6. 计算 nonceHash，可查询 ActivateProofNonce 是否已被成功使用过；如果已使用，快速返回 replay 错误。此步骤不得写入 consumed。
7. 按固定格式重建 proof message。
8. 将 raw devicePublicKey 转 SPKI DER KeyObject。
9. 验证 Ed25519 signature。
10. 如果验签失败，返回 INVALID_ACTIVATE_PROOF，且不得创建或消费 ActivateProofNonce。
11. 如果验签成功，在数据库事务中原子消费 ActivateProofNonce：唯一插入 nonceHash + deviceKeyThumbprint，设置 consumedAt = now。
12. 如果唯一插入失败，说明 nonce 已被成功 proof 使用过，返回 ACTIVATE_PROOF_REPLAYED 或 INVALID_ACTIVATE_PROOF。
13. nonce 消费成功后，才继续 license/email/seat 校验和 activation 创建或重激活。
```

注意：activate proof 不是为了隐藏 email 或 licenseCode；它的目标是防止服务端绑定一个客户端并未实际持有 private key 的公钥。

### 13.3 refresh/deactivate challenge 流程

refresh 和 deactivate 都必须先获取 challenge。

流程：

```text
1. 客户端 POST /v1/licenses/refresh/challenge，传 activationId。
2. 服务端生成 challengeId 和 nonce，有效期 5 分钟。
3. 客户端用 devicePrivateKey 签名 proof message。
4. 客户端 POST /v1/licenses/refresh 或 /deactivate。
5. 服务端用该 activation 绑定的 devicePublicKey 验签。
6. 验签成功后才刷新证书或停用设备。
```

### 13.4 refresh/deactivate proof message

必须使用固定格式，避免不同端拼接不一致：

```text
PromptStudio-Device-Proof-v1
activationId:{activationId}
challengeId:{challengeId}
nonce:{nonce}
bundleId:{bundleId}
```

客户端签名 UTF-8 字节。

服务端验签同一字符串。

### 13.5 challenge 规则

1. challenge 有效期 5 分钟。
2. challenge 只能消费一次。
3. challenge 必须绑定 activationId。
4. 过期或已消费的 challenge 返回 `INVALID_CHALLENGE`。
5. 签名失败返回 `INVALID_DEVICE_PROOF`。

---

## 14. 后端 API 规格

所有 API 使用 JSON。Phase 1 可以只允许 macOS app 使用，无需 CORS 给浏览器 Portal。

### 14.1 通用响应

成功：

```json
{
  "ok": true
}
```

失败：

```json
{
  "ok": false,
  "error": {
    "code": "ERROR_CODE",
    "message": "用户可理解的错误文案"
  }
}
```

HTTP 状态码建议：

| 场景 | HTTP |
|---|---:|
| 成功 | 200 |
| 请求格式错误 | 400 |
| 邮箱或激活码不匹配 | 401 |
| 授权不可用/撤销 | 403 |
| 设备数超限 | 409 |
| 限频 | 429 |
| 服务端错误 | 500 |

### 14.2 POST /v1/licenses/activate

用于首次激活或新设备激活。

请求：

```json
{
  "email": "user@example.com",
  "licenseCode": "PS-XXXX-XXXX-XXXX-XXXX-XXXX",
  "installIdHash": "base64url-sha256-install-id",
  "devicePublicKey": "base64url-ed25519-raw-public-key-32-bytes",
  "deviceProof": {
    "version": "PromptStudio-Activate-Proof-v1",
    "clientNonce": "base64url-random-16-to-32-bytes",
    "createdAt": "2026-06-15T15:00:00.000Z",
    "signature": "base64url-ed25519-signature"
  },
  "deviceLabel": "MacBook Pro - macOS 15",
  "bundleId": "com.promptstudio.app",
  "appVersion": "1.0.0",
  "osVersion": "macOS 15.5"
}
```

校验：

1. email 格式基本合法。
2. licenseCode 归一化后计算 codeHash。
3. email 归一化后计算 emailHash。
4. `devicePublicKey` 必须是 Ed25519 raw public key 32 bytes 的 base64url。
5. 必须按 13.2 验证 `deviceProof`。签名失败返回 `INVALID_ACTIVATE_PROOF`，且不得消费 `ActivateProofNonce`。
6. `deviceProof` 验签成功后，必须在数据库事务中原子消费 `ActivateProofNonce`；唯一冲突时返回 `ACTIVATE_PROOF_REPLAYED` 或 `INVALID_ACTIVATE_PROOF`。
7. `bundleId` 必须匹配服务端允许的 `LICENSE_BUNDLE_ID`。
8. 查找匹配 license。
9. 如果不匹配，返回统一 `INVALID_EMAIL_OR_LICENSE`，不得暴露是邮箱错还是激活码错。
10. license status 必须是 `unused` 或 `active`。
11. 如果 status 是 `refunded/revoked/disabled`，返回 `LICENSE_NOT_AVAILABLE`。
12. 如果相同 licenseId + installIdHash 已存在 active activation 且 deviceKeyThumbprint 相同，可视为同设备重激活，返回新证书，不重复占 seat。
13. 如果相同 licenseId + installIdHash 已存在 active activation 但 deviceKeyThumbprint 不同，视为同一安装 device key 重建：事务内将旧 activation 标记为 `stale`，再创建新 activation，不额外占用一个 seat。
14. 其他新设备激活时，active activation 数量必须小于 seatLimit。
15. 超限时返回 `SEAT_LIMIT_EXCEEDED` 和设备摘要。

成功响应：

```json
{
  "ok": true,
  "activationId": "act_...",
  "licenseCertificate": "header.payload.signature",
  "refreshAfter": "2026-06-22T00:00:00.000Z",
  "expiresAt": "2026-07-15T00:00:00.000Z",
  "graceUntil": "2026-07-29T00:00:00.000Z",
  "deviceCount": 1,
  "seatLimit": 2
}
```

设备超限响应：

```json
{
  "ok": false,
  "error": {
    "code": "SEAT_LIMIT_EXCEEDED",
    "message": "该激活码已达到设备上限。",
    "deviceCount": 2,
    "seatLimit": 2,
    "devices": [
      {
        "activationId": "act_...",
        "deviceLabel": "MacBook Pro - macOS 15",
        "activatedAt": "2026-06-01T00:00:00.000Z",
        "lastSeenAt": "2026-06-14T00:00:00.000Z"
      }
    ]
  }
}
```

注意：只有 email + licenseCode 已经校验通过但 seat 已满时，才能返回设备摘要。

### 14.3 POST /v1/licenses/refresh/challenge

请求：

```json
{
  "activationId": "act_..."
}
```

响应：

```json
{
  "ok": true,
  "challengeId": "ch_...",
  "nonce": "base64url-random-nonce",
  "expiresAt": "2026-06-15T15:00:00.000Z"
}
```

失败：

```json
{
  "ok": false,
  "error": {
    "code": "ACTIVATION_NOT_FOUND",
    "message": "当前设备授权不存在或已失效。"
  }
}
```

### 14.4 POST /v1/licenses/refresh

请求：

```json
{
  "activationId": "act_...",
  "challengeId": "ch_...",
  "signature": "base64url-device-signature",
  "appVersion": "1.0.3",
  "osVersion": "macOS 15.5"
}
```

成功响应：

```json
{
  "ok": true,
  "licenseCertificate": "header.payload.signature",
  "refreshAfter": "2026-06-22T00:00:00.000Z",
  "expiresAt": "2026-07-15T00:00:00.000Z",
  "graceUntil": "2026-07-29T00:00:00.000Z",
  "status": "active"
}
```

如果 license 已 revoked/refunded：

```json
{
  "ok": false,
  "error": {
    "code": "LICENSE_REVOKED",
    "message": "该授权当前不可用。"
  }
}
```

客户端收到 `LICENSE_REVOKED` 后进入 `revoked`/`limited`，但不得删除用户资料库。

### 14.5 POST /v1/licenses/deactivate

Phase 1 只支持停用当前设备。

请求：

```json
{
  "activationId": "act_...",
  "challengeId": "ch_...",
  "signature": "base64url-device-signature",
  "reason": "user_requested"
}
```

成功响应：

```json
{
  "ok": true
}
```

服务端行为：

1. 校验 challenge 和签名。
2. activation status 改为 `deactivated`。
3. 设置 `deactivatedAt`、`deactivatedReason`。
4. 写入 `device_deactivated` 事件。
5. 不删除 activation 记录。

客户端行为：

1. 删除本地 license certificate。
2. 删除本地 activationId。
3. 可保留 installId 和 device key，也可重新生成；建议保留，减少重复设备记录。
4. 不删除用户数据。

### 14.6 POST /v1/licenses/recover

Phase 1 是安全占位，不发送真实邮件。

请求：

```json
{
  "email": "user@example.com"
}
```

响应永远：

```json
{
  "ok": true
}
```

服务端行为：

1. 记录 `license_recover_requested` 事件。
2. 做限频。
3. 不暴露邮箱是否存在。
4. Phase 2 再接入邮件发送。

客户端 Phase 1 文案必须明确这是占位能力：

```text
已收到找回请求。

为保护隐私，我们不会在此确认该邮箱是否存在。Phase 1 暂不会自动发送找回邮件。请使用购买邮箱联系支持，并提供订单号或激活码后 4 位。
```

客户端不得显示：

```text
请查收邮件
我们已发送激活码
```

---

## 15. API 错误码

| 错误码 | 场景 | 用户提示 |
|---|---|---|
| `INVALID_REQUEST` | JSON/schema 不合法 | 请求格式不正确。 |
| `INVALID_EMAIL_OR_LICENSE` | 邮箱或激活码不匹配 | 邮箱或激活码不匹配，请检查购买邮件。 |
| `LICENSE_NOT_AVAILABLE` | license disabled/refunded/revoked | 该授权当前不可用，如有疑问请联系支持。 |
| `LICENSE_REVOKED` | refresh 时发现撤销 | 该授权当前不可用。 |
| `SEAT_LIMIT_EXCEEDED` | 激活设备数已满 | 该激活码已达到设备上限。 |
| `ACTIVATION_NOT_FOUND` | activation 不存在 | 当前设备授权不存在或已失效。 |
| `INVALID_CHALLENGE` | challenge 不存在、过期或已消费 | 授权验证已过期，请重试。 |
| `INVALID_ACTIVATE_PROOF` | 首次激活设备签名验证失败 | 无法验证当前设备，请重试。 |
| `INVALID_DEVICE_PROOF` | refresh/deactivate 设备签名验证失败 | 无法验证当前设备授权。 |
| `INVALID_BUNDLE_ID` | bundleId 不匹配 | 当前应用无法使用此授权。 |
| `RATE_LIMITED` | 请求过于频繁 | 请求过于频繁，请稍后再试。 |
| `SERVER_ERROR` | 服务端异常 | 授权服务暂时不可用，请稍后再试。 |

---

## 16. 基础限频和事件日志

### 16.1 限频维度

Phase 1 实现内存限频即可，后续可换 Redis。

至少限制：

| API | 维度 | 建议限制 |
|---|---|---|
| activate | IP hash | 20 次 / 10 分钟 |
| activate | emailHash | 10 次 / 10 分钟 |
| activate | codePrefix | 20 次 / 10 分钟 |
| challenge | activationId | 30 次 / 10 分钟 |
| refresh | activationId | 30 次 / 10 分钟 |
| recover | emailHash | 3 次 / 小时 |

### 16.2 IP 和 UA 记录

事件表可保存：

```text
ipHash = HMAC_SHA256(LICENSE_CODE_PEPPER, ip)
userAgentHash = HMAC_SHA256(LICENSE_CODE_PEPPER, userAgent)
```

不要在数据库长期保存明文 IP 或完整 User-Agent，除非后续隐私政策明确说明。

### 16.3 事件类型

Phase 1 至少记录：

```text
license_created
license_revoked
license_seats_added
license_code_rotated
activation_success
activation_failed
seat_limit_exceeded
refresh_challenge_created
refresh_success
refresh_failed
device_deactivated
license_recover_requested
rate_limited
```

事件 metadata 不得包含：

```text
完整 license code
device private key
Prompt 内容
文件路径
API Key
```

---

## 17. Admin CLI

### 17.1 CLI 总入口

```bash
cd license-server
npm run cli -- <command> [options]
```

### 17.2 创建 license

命令：

```bash
npm run cli -- license:create --email user@example.com --plan pro_lifetime --seats 2
```

输出：

```text
License created.
Email: u***@example.com
Plan: pro_lifetime
Seats: 2
License code: PS-7K4D-M9QF-2X8P-R6TA-B3HE

IMPORTANT: This license code is shown only once. Store it in the purchase email.
```

要求：

1. 明文 license code 只在 create 输出一次。
2. 数据库只保存 codeHash/codePrefix/codeMasked。
3. CLI 日志不能重复输出完整 code。

### 17.3 列出 license

```bash
npm run cli -- license:list --email user@example.com
```

输出：

```text
ID: lic_...
Email: u***@example.com
Code: PS-7K4D-****-B3HE
Plan: pro_lifetime
Status: active
Seats: 2
Active devices: 1
Created: 2026-06-15
```

### 17.4 增加 seat

```bash
npm run cli -- license:add-seats --license-id lic_... --seats 1
```

### 17.5 撤销 license

```bash
npm run cli -- license:revoke --license-id lic_... --reason "refund"
```

### 17.6 停用某个设备

```bash
npm run cli -- license:deactivate-device --activation-id act_... --reason "support_request"
```

用于 Phase 1 处理旧设备丢失、电脑损坏、用户换机。

### 17.7 轮换激活码

```bash
npm run cli -- license:rotate-code --license-id lic_... --reason "leaked_code"
```

行为：

1. 为同一个 license 生成新的 codeHash/codePrefix/codeMasked。
2. 输出新明文 code 一次。
3. 记录 `license_code_rotated` 事件。
4. 旧 code 立即失效。

---

## 18. macOS 客户端技术规格

### 18.1 模块列表

授权代码集中放在 `License/` 目录。

必须实现：

```text
LicenseState.swift
FeatureKey.swift
FeatureGate.swift
LicenseCertificate.swift
LicenseCertificateVerifier.swift
LicenseManager.swift
LicenseAPIClient.swift
TrialManager.swift
DeviceIdentityManager.swift
KeychainLicenseStore.swift
ActivationViewModel.swift
LicenseSettingsView.swift
ActivationSheetView.swift
```

### 18.2 Keychain 存储

Keychain 中保存：

| Key | 内容 | 说明 |
|---|---|---|
| `promptstudio.installId` | 随机 installId | 不使用硬件 ID。 |
| `promptstudio.devicePrivateKey` | 设备签名私钥 | 不得出现在日志。 |
| `promptstudio.devicePublicKey` | 设备公钥 | 可从 private key 派生，也可缓存。 |
| `promptstudio.activationId` | 当前设备 activationId | 激活成功后保存。 |
| `promptstudio.licenseCertificate` | 服务端签名证书 | 离线验签依据。 |
| `promptstudio.trialStartedAt` | 试用开始时间 | 用于 30 天试用。 |
| `promptstudio.lastTrustedServerTime` | 最近服务端时间 | 用于简单防本地时间回拨。 |

不得保存在 UserDefaults：

```text
isPro = true
licenseCode 明文
devicePrivateKey
```

### 18.3 DeviceIdentityManager

职责：

1. 读取或创建 installId。
2. 读取或创建设备密钥对。
3. 生成 installIdHash。
4. 生成 devicePublicKey。
5. 生成 deviceKeyThumbprint。
6. 对 challenge proof message 签名。

伪代码：

```swift
final class DeviceIdentityManager {
    func getOrCreateInstallId() throws -> String
    func installIdHash() throws -> String
    func getOrCreateDeviceKeyPair() throws -> DeviceKeyPair
    func devicePublicKeyBase64URL() throws -> String
    func deviceKeyThumbprint() throws -> String
    func signProofMessage(activationId: String, challengeId: String, nonce: String, bundleId: String) throws -> String
}
```

### 18.4 TrialManager

职责：

1. 首次启动创建 trial start time。
2. 计算剩余天数。
3. 判断试用是否过期。
4. 不需要联网。

规则：

```text
试用期：30 天
试用期内：全部 Pro 功能
试用过期：Base 安全能力
```

存储策略：

1. `trialStartedAt` 存 Keychain。
2. 可选：Application Support 下保存一个备份 trial 文件。
3. 如果两个位置都有值，取更早时间，避免简单重置试用。
4. 不要为了防止极少数人反复试用而破坏正常用户体验。

### 18.5 LicenseCertificateVerifier

职责：

1. 解析 JWS-like license certificate。
2. 根据 `kid` 找到内置 public key。
3. 验证 EdDSA 签名。
4. 校验 issuer/audience/bundleId。
5. 校验 activationId 和 deviceKeyThumbprint。
6. 校验 version/update 权益。
7. 返回解析后的 `LicenseCertificate`。

伪代码：

```swift
final class LicenseCertificateVerifier {
    func verify(_ certificateString: String, expectedActivationId: String, expectedDeviceKeyThumbprint: String) throws -> LicenseCertificate
}
```

### 18.6 LicenseAPIClient

职责：

1. 调用 activate。
2. 调用 refresh challenge。
3. 调用 refresh。
4. 调用 deactivate。
5. 调用 recover 占位。
6. 统一错误码映射。

伪代码：

```swift
final class LicenseAPIClient {
    func activate(request: ActivateRequest) async throws -> ActivateResponse
    func refreshChallenge(activationId: String) async throws -> RefreshChallengeResponse
    func refresh(request: RefreshRequest) async throws -> RefreshResponse
    func deactivate(request: DeactivateRequest) async throws
    func recover(email: String) async throws
}
```

### 18.7 LicenseManager 状态机

启动时：

```swift
func loadStateOnLaunch() {
    if let certString = keychain.licenseCertificate,
       let activationId = keychain.activationId,
       let deviceThumbprint = deviceIdentity.deviceKeyThumbprint(),
       let cert = try? verifier.verify(certString, expectedActivationId: activationId, expectedDeviceKeyThumbprint: deviceThumbprint) {

        if trustedClock.now <= cert.expiresAt {
            state = .proActive(certificate: cert)
            scheduleRefreshIfNeeded(cert)
            return
        }

        if trustedClock.now <= cert.graceUntil {
            state = .grace(certificate: cert, daysRemaining: daysUntil(cert.graceUntil))
            scheduleRefreshIfNeeded(cert)
            return
        }
    }

    let trial = trialManager.currentTrialState()
    switch trial {
    case .active(let days): state = .trialActive(daysRemaining: days)
    case .expired: state = .trialExpired
    }
}
```

激活成功后：

```text
1. 保存 activationId。
2. 保存 licenseCertificate。
3. 保存 lastTrustedServerTime。
4. 重新 resolve state。
5. UI 显示激活成功。
```

刷新失败时：

```text
网络失败：保留本地证书状态，不立即降级。
LICENSE_REVOKED：进入 revoked/limited。
INVALID_DEVICE_PROOF：进入 limited(deviceMismatch)。
SERVER_ERROR：保留本地证书状态。
```

### 18.8 TrustedClock

Phase 1 实现轻量防时间回拨：

1. 每次从服务端获得证书响应时保存 `serverTime` 或响应中的时间。
2. 如果本地时间明显早于 `lastTrustedServerTime - 24h`，进入 `limited(clockInvalid)` 或要求联网刷新。
3. 不要因为几分钟时钟误差惩罚用户。

---

## 19. UI 需求

### 19.1 License 设置页入口

路径：

```text
Settings → License
```

若项目已有设置页，新增 License tab/section。

### 19.2 Trial Active 状态

```text
PromptStudio Pro 试用中
剩余 18 天

试用期内可使用全部 Pro 功能。试用结束后，你仍可以打开、搜索、复制和导出已有数据。

[输入激活码]
[购买 Pro]
```

`购买 Pro` Phase 1 可打开官网 URL 或 TODO 占位，不阻塞验收。

### 19.3 Pro Active 状态

```text
PromptStudio Pro 已激活

授权类型：Pro Lifetime
当前设备：MacBook Pro - macOS 15
设备额度：1 / 2
下次授权刷新：2026-06-22

[立即刷新]
[停用当前设备]
```

Phase 1 如果没有 `/devices` API，设备额度可以使用 activate/refresh 响应中的缓存值或只显示 license seatLimit 信息。

### 19.4 Grace 状态

```text
PromptStudio Pro 需要联网刷新

你的本地授权仍在宽限期内，Pro 功能可继续使用。请在 14 天内联网刷新授权。

[立即刷新]
```

### 19.5 Trial Expired / Limited 状态

```text
PromptStudio Pro 当前不可用

你仍可以打开、搜索、复制和导出已有数据。要继续使用新建、编辑、批量导入、AI 辅助和高级功能，请激活 Pro。

[输入激活码]
[导出数据]
```

### 19.6 Revoked 状态

```text
授权当前不可用

你仍可以打开、搜索、复制和导出已有数据。如认为这是误判，请联系支持。

[输入新的激活码]
[联系支持]
```

### 19.7 激活弹窗

字段：

```text
购买邮箱
激活码
```

说明文案：

```text
PromptStudio 需要联网验证激活码并管理设备授权。授权校验不会上传你的 Prompt、文件、图片、API Key 或本地路径。
```

按钮：

```text
[激活 PromptStudio Pro]
[找回激活码]
```

交互：

1. 邮箱输入 trim。
2. 激活码自动大写。
3. 激活码允许带横杠/空格。
4. 点击激活后禁用按钮并显示 loading。
5. 激活前生成或读取 installId、device key pair，并按 `PromptStudio-Activate-Proof-v1` 生成 deviceProof。
6. 成功后关闭弹窗并刷新 License 设置页。
7. 失败时展示错误文案。

“找回激活码” Phase 1 交互：

1. 用户输入邮箱后点击。
2. 客户端调用 `/v1/licenses/recover`，或在没有网络时直接显示联系支持文案。
3. 成功和失败都不得透露邮箱是否存在。
4. UI 文案必须是：

```text
已收到找回请求。

为保护隐私，我们不会在此确认该邮箱是否存在。Phase 1 暂不会自动发送找回邮件。请使用购买邮箱联系支持，并提供订单号或激活码后 4 位。
```

不得显示“请查收邮件”。

### 19.8 Pro Gate 弹窗

当用户在 Limited/TrialExpired/Revoked 状态触发 Pro 功能，显示统一弹窗：

```text
需要 PromptStudio Pro

该功能属于 Pro 功能。你仍可以打开、搜索、复制和基础导出已有数据。

[输入激活码]
[了解 Pro]
```

具体功能名可替换标题：

```text
批量导入需要 PromptStudio Pro
AI 辅助需要 PromptStudio Pro
高级导出需要 PromptStudio Pro
```

---

## 20. 服务端业务流程

### 20.1 创建 license

```text
Admin CLI 输入 email、plan、seats
→ normalize email
→ emailHash/emailMasked
→ 查找或创建 Customer
→ 生成 license code
→ normalize code
→ HMAC codeHash
→ 保存 License
→ 输出明文 code 一次
→ 写 license_created 事件
```

### 20.2 激活

```text
客户端输入 email/code
→ 客户端准备 installIdHash/devicePublicKey/deviceLabel
→ 客户端生成 clientNonce 和 PromptStudio-Activate-Proof-v1 signature
→ POST activate
→ 服务端限频
→ 服务端校验 JSON/devicePublicKey/clientNonce/createdAt
→ 服务端重建 activate proof message 并验签
→ 如果验签失败：返回 INVALID_ACTIVATE_PROOF，不消费 ActivateProofNonce
→ 如果验签成功：在事务中原子消费 ActivateProofNonce
→ 如果 nonce 唯一冲突：返回 ACTIVATE_PROOF_REPLAYED，不创建 activation
→ 服务端校验 email/code
→ 校验 license status
→ 查找是否已有相同 installIdHash activation
→ 若已有 active activation：刷新证书并返回
→ 若没有：检查 active activation 数量 < seatLimit
→ 创建 activation
→ license status 从 unused 改 active
→ 签发 license certificate
→ 写 activation_success 事件
→ 返回 activationId + certificate
```

### 20.3 refresh

```text
客户端发现需要刷新
→ POST refresh/challenge
→ 服务端创建 nonce/challengeId
→ 客户端签名 proof message
→ POST refresh
→ 服务端校验 challenge 未过期未消费
→ 服务端用 activation.devicePublicKey 验签
→ 检查 license/activation 状态
→ 更新 lastSeenAt/appVersion/osVersion
→ 签发新 certificate
→ 标记 challenge consumed
→ 写 refresh_success 事件
→ 返回 certificate
```

### 20.4 deactivate 当前设备

```text
客户端获取 challenge
→ 客户端签名 proof message
→ POST deactivate
→ 服务端验签
→ activation.status = deactivated
→ 记录 deactivatedAt/reason
→ 写 device_deactivated 事件
→ 客户端删除本地 certificate/activationId
```

---

## 21. 安全要求

### 21.1 服务端

1. 所有输入用 Zod 校验。
2. license code 只存 HMAC hash。
3. email 用 normalized hash 匹配。
4. 不在日志输出完整 license code。
5. 不在日志输出 signature private key。
6. API 错误不能枚举邮箱或激活码是否存在。
7. seat 超限设备列表只在 email + code 正确时返回。
8. challenge 单次使用，过期失效。
9. refresh/deactivate 必须验证设备签名。
10. signing private key 只能服务端读取。
11. Prisma 查询避免 SQL 注入。
12. 生产环境必须使用 HTTPS。

### 21.2 客户端

1. device private key 存 Keychain。
2. license certificate 存 Keychain。
3. 不把 `isPro` 存 UserDefaults。
4. 不把 license code 明文长期保存。
5. 不上传用户内容。
6. 离线验签失败时不能进入 Pro。
7. 证书过期宽限结束后进入 Limited。
8. 即使授权无效，也不得删除资料库。
9. 所有 Pro 功能必须通过 FeatureGate。

### 21.3 隐私边界

授权 API 允许上传：

```text
购买邮箱
激活码
installIdHash
devicePublicKey
deviceLabel
appVersion
osVersion
activationId
challenge signature
```

不得上传：

```text
Prompt 正文
Prompt 标题
标签名
集合名
文件名
本地路径
图片/视频内容
附件内容
API Key
剪贴板内容
Mac 序列号
本地用户名
```

---

## 22. 测试计划

### 22.1 后端单元测试

必须覆盖：

1. license code 生成长度和字符集。
2. license code normalize。
3. code hash 稳定性。
4. masked code 不泄露完整 code。
5. certificate 签名和验签。
6. certificate payload 时间字段。
7. proof message 拼接一致。
8. rate limiter 基础行为。

### 22.2 后端集成测试

必须覆盖：

1. 创建 license 后可激活。
2. 邮箱错误返回 `INVALID_EMAIL_OR_LICENSE`。
3. license code 错误返回 `INVALID_EMAIL_OR_LICENSE`。
4. 第一台设备激活成功。
5. 第二台设备激活成功。
6. 第三台设备返回 `SEAT_LIMIT_EXCEEDED`。
7. 相同 installIdHash 重复激活不重复占 seat。
8. refresh challenge 创建成功。
9. refresh 签名正确时成功。
10. refresh 签名错误时失败。
11. challenge 只能使用一次。
12. deactivate 当前设备成功释放 seat。
13. revoked license 无法 refresh。
14. recover 永远返回 ok。
15. activate proof 签名失败时不得创建或消费 `ActivateProofNonce`。
16. 同一个 `clientNonce + deviceKeyThumbprint`，先发一次错误签名请求，再发一次正确签名请求，正确请求必须可以激活成功。
17. 同一个 `clientNonce + deviceKeyThumbprint`，一次正确签名请求成功后，第二次完全重放必须失败。
18. 并发提交两个相同的正确 activate proof，最多一个请求能消费 nonce 并继续激活。

### 22.3 客户端单元测试

必须覆盖：

1. 无证书且 trial 未过期 → `trialActive`。
2. 无证书且 trial 过期 → `trialExpired`。
3. 有效证书 → `proActive`。
4. 过期但 grace 内 → `grace`。
5. 超过 grace → `limited`。
6. 签名被篡改 → `limited(invalidCertificate)`。
7. activationId 不匹配 → `limited(deviceMismatch)`。
8. deviceKeyThumbprint 不匹配 → `limited(deviceMismatch)`。
9. FeatureGate 在 trial/pro/grace 允许 Pro 功能。
10. FeatureGate 在 trialExpired/limited/revoked 禁止 Pro 功能。
11. Base 功能在所有状态允许。

### 22.4 手工 E2E 验收清单

开发者按以下步骤手工验证：

```text
1. 启动 Postgres。
2. 启动 license-server。
3. 用 CLI 创建测试 license。
4. 启动 PromptStudio。
5. 确认首次启动显示 30 天试用。
6. 输入购买邮箱 + 激活码。
7. 激活成功，显示 Pro Active。
8. 断网并重启 app，仍为 Pro Active。
9. 修改本地证书任意字符，重启后不能 Pro。
10. 用第二个 installId/模拟第二台设备激活成功。
11. 用第三个 installId/模拟第三台设备激活失败且提示 seat limit。
12. 当前设备停用成功，seat 释放。
13. 试用过期或模拟过期后，Pro 功能被拦截。
14. Limited 状态仍可打开、查看、搜索、复制、基础导出已有数据。
15. 日志中没有完整 license code、Prompt 内容、API Key、device private key。
```

---

## 23. 验收标准

Phase 1 完成必须满足：

1. `license-server` 可本地启动。
2. Prisma migration 可执行。
3. Admin CLI 可创建 license。
4. 明文 license code 只输出一次。
5. 客户端可输入 email + code 激活 Pro。
6. 一个 license 默认最多 2 台 active 设备。
7. 第 3 台设备激活被拒绝。
8. 客户端保存服务端签名证书到 Keychain。
9. 客户端离线可验签并进入 Pro。
10. 证书被篡改后不能进入 Pro。
11. refresh/deactivate 必须使用 device private key 签名。
12. activate proof 签名失败不得消费 ActivateProofNonce；同 nonce 后续合法签名请求必须仍可成功。
13. activate proof 合法请求成功后，同 nonce 重放必须失败。
14. 当前设备停用可释放 seat。
15. 试用期 30 天内全功能。
16. 试用过期后进入 Limited/Base。
17. Grace 状态 Pro 功能继续可用并提示联网刷新。
18. Limited 状态不允许 Pro 写入/高级功能。
19. Limited 状态必须允许打开、查看、基础搜索、复制、基础导出。
20. 所有 Pro 功能通过统一 FeatureGate。
21. 没有散落的 `isPro` 作为最终授权判断。
22. 不上传用户 Prompt、标题、标签、路径、文件、图片、API Key、剪贴板。
23. 后端测试通过。
24. 客户端核心测试通过或提供可执行手工验证结果。

---

## 24. Codex 开发任务拆分

Codex 按下面顺序实现，不能跳到后续 Phase。

### Task 0：扫描现有项目结构，并生成 FeatureGate 接入清单

1. 确认 Swift app 目录。
2. 确认设置页位置。
3. 确认 Prompt 新建/编辑/保存/导入/导出/搜索/AI/自动化功能入口。
4. 确认菜单、快捷键、右键菜单、toolbar、command palette 是否能触发这些功能。
5. 确认真正执行写入或高级能力的 service/repository/use-case 方法。
6. 确认是否已有 Keychain、HTTP client、日志组件。
7. 必须新增 `docs/license_feature_gate_inventory.md`，列出所有需要接入 FeatureGate 的文件和状态。

`docs/license_feature_gate_inventory.md` 表格格式：

```markdown
| FeatureKey | UI 入口文件 | 菜单/快捷键入口 | 服务层入口文件 | 接入优先级 | 接入状态 | 备注 |
|---|---|---|---|---|---|---|
| pro.create_prompt | ... | ... | ... | P0 | UI+Service Done | ... |
```

规则：

1. 已存在的 P0 功能必须做到 UI 层和服务层双重 gating。
2. 如果某个 PRD 中的功能在当前代码不存在，状态写 `Not implemented in current app`，不要凭空造复杂功能。
3. 如果只有 UI 层没有明确 service 层，必须在最靠近数据写入或业务执行的边界增加 `FeatureGate.assertAllowed`。
4. Codex 不能只隐藏按钮；服务层入口漏 gate 视为 Phase 1 不通过。

### Task 1：创建 license-server 基础工程

1. 新增 `license-server/`。
2. 初始化 package.json、tsconfig。
3. 配置 Fastify。
4. 增加 health route。
5. 增加 Dockerfile、docker-compose、README、.env.example。

### Task 2：实现 Prisma schema 和数据库

1. 编写 schema。
2. 运行 migration。
3. 添加 Prisma client。
4. 添加 seed 或 dev helper 可选。

### Task 3：实现 crypto 工具

1. base64url。
2. license code generate/normalize/mask/hash。
3. email normalize/hash/mask。
4. Ed25519 signing，必须支持 PKCS8 DER private key 导入。
5. Ed25519 raw public key 32 bytes 与 SPKI DER 互转。
6. certificate sign/verify 测试。
7. activate proof message builder。
8. refresh/deactivate proof message builder。
9. 两端共用 fixture 生成脚本或 README。

### Task 4：实现 Admin CLI

1. `license:create`。
2. `license:list`。
3. `license:add-seats`。
4. `license:revoke`。
5. `license:deactivate-device`。
6. `license:rotate-code`。

### Task 5：实现后端服务层

1. LicenseService。
2. ActivationService。
3. CertificateService。
4. DeviceProofService。
5. RateLimitService。
6. AuditEventService。

### Task 6：实现 API routes

1. activate。
2. refresh/challenge。
3. refresh。
4. deactivate。
5. recover。
6. error mapping。
7. Zod validation。

### Task 7：实现后端测试

1. 单元测试。
2. 集成测试。
3. 设备数超限测试。
4. activate proof 缺失或签名失败测试。
5. activate proof 签名失败不消费 nonce 测试：同 nonce 先失败、后成功必须能激活。
6. activate proof 成功后重放 nonce 必须失败测试。
7. activate proof 并发相同 nonce 只能一个成功消费测试。
8. refresh/deactivate 签名失败测试。
9. challenge 重放测试。
10. 同一 `licenseId + installIdHash` 相同 deviceKey 重激活不占 seat 测试。
11. 同一 `licenseId + installIdHash` 不同 deviceKey 重建时旧 activation 变 `stale` 测试。
12. PKCS8 DER private key 签证书、raw public key 验签 fixture 测试。

### Task 8：实现 Swift 授权基础模型

1. LicenseState。
2. LicenseCertificate。
3. FeatureKey。
4. FeatureDecision。
5. 错误类型。

### Task 9：实现 Keychain 和设备身份

1. KeychainLicenseStore。
2. DeviceIdentityManager。
3. installId。
4. device key pair。
5. device public key raw 32 bytes base64url 导出。
6. `PromptStudio-Activate-Proof-v1` 签名。
7. `PromptStudio-Device-Proof-v1` 签名。

### Task 10：实现证书验签

1. JWS-like parser。
2. public key map。
3. signature verification。
4. payload validation。
5. unit tests。

### Task 11：实现 API client

1. activate。
2. challenge。
3. refresh。
4. deactivate。
5. recover。
6. error mapping。

### Task 12：实现 TrialManager 和 LicenseManager

1. 30 天试用。
2. 启动状态解析。
3. 激活流程。
4. 刷新流程。
5. 停用流程。
6. Grace/Limited 状态处理。

### Task 13：实现 FeatureGate

1. Base/Pro 判定。
2. FeatureDecision。
3. UI 统一提示。
4. 服务层 assert。

### Task 14：实现 UI

1. License 设置页。
2. 激活弹窗。
3. 激活成功/失败提示。
4. Grace 提示。
5. Limited 提示。
6. 当前设备停用确认弹窗。

### Task 15：接入 PromptStudio 业务功能

先基于 `docs/license_feature_gate_inventory.md` 接入，不要盲目按列表凭空改代码。

P0：当前代码中只要存在，必须在 Phase 1 完成 UI + 服务层双重 gate：

1. 新建 Prompt。
2. 编辑 Prompt / 保存 Prompt 修改。
3. 复制为新 Prompt。
4. 单个导入。
5. 批量导入。
6. AI 辅助。
7. 自动化/批处理。
8. 高级导出。
9. 高级搜索。
10. 模板保存/变量保存，如果当前代码已存在。

P1：当前代码中存在时也要尽量完成；如果结构复杂，至少必须在 inventory 中写明剩余入口和风险：

1. 标签管理。
2. 集合/文件夹管理。
3. 模板管理。
4. 自定义变量。

Base 能力必须验证不被误挡：

1. 打开资料库。
2. 查看已有 Prompt。
3. 复制已有 Prompt 内容。
4. 基础关键词搜索。
5. 基础 JSON/Markdown 导出。
6. 删除本地数据或删除本地 Prompt。
7. 打开 License 设置页。

服务层规则：

1. 任何修改 Prompt library 的入口都必须有 `FeatureGate.assertAllowed(...)`，除非它是明确的 Base 删除/导出/复制能力。
2. 菜单、快捷键、右键菜单、toolbar、命令面板必须与按钮使用同一套 gate。
3. 单元测试或手工测试必须覆盖 Limited 状态下直接调用服务层写入方法会失败。

### Task 16：E2E 验证和输出报告

完成后输出：

1. 变更文件列表。
2. 本地启动方式。
3. 如何创建测试 license。
4. 如何端到端激活。
5. 如何模拟第二/第三台设备。
6. 如何验证离线证书。
7. 如何验证篡改证书失败。
8. 如何验证 FeatureGate。
9. 测试结果。
10. 未完成项和 Phase 2 TODO。

---

## 25. 本地开发运行说明，Codex 需在 README 中落地

### 25.1 启动后端

```bash
cd license-server
cp .env.example .env
# 填写 LICENSE_CODE_PEPPER 和 LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64
npm install
docker compose up -d
npm run prisma:migrate
npm run dev
```

### 25.2 生成 dev signing key

Codex 需要提供脚本或 README 说明，例如：

```bash
npm run cli -- keys:generate-dev
```

输出：

```text
LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64=...
LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL=...
LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64=...
LICENSE_SIGNING_KEY_ID=dev-key-1
```

`keys:generate-dev` 还必须生成或更新测试 fixture：

```text
license-server/tests/fixtures/ed25519_dev_private.pkcs8.der.b64
license-server/tests/fixtures/ed25519_dev_public.raw.b64url
license-server/tests/fixtures/ed25519_dev_public.spki.der.b64
license-server/tests/fixtures/license_certificate_valid.txt
```

如果不实现 `keys:generate-dev`，也必须在 README 写清楚如何生成 PKCS8 DER private key、raw 32 bytes public key 和 SPKI DER public key。

### 25.3 创建测试 license

```bash
npm run cli -- license:create --email user@example.com --plan pro_lifetime --seats 2
```

### 25.4 客户端配置 dev server

客户端需要支持 dev base URL：

```text
http://localhost:8787
```

生产环境再改成正式域名。

---

## 26. 后续 Phase 2 TODO

Phase 1 完成后，下一步实现：

1. License Portal。
2. 邮箱 OTP。
3. 用户远程解绑旧设备。
4. 找回激活码邮件。
5. 支付 webhook 自动创建 license。
6. 匿名 telemetry 开关。
7. 复杂风控。
8. 客服后台。

这些 TODO 不影响 Phase 1 上线。

---

## 27. 最终给 Codex 的执行 Prompt

可以直接复制下面这段给 Codex：

```text
请完整阅读 docs/PromptStudio_Activation_Core_MVP_PRD_v1.4.md，并严格按照文档实现 PromptStudio 激活授权系统 Phase 1：Activation Core MVP。

本轮只实现 Phase 1，不实现 Portal、OTP 网页、telemetry、支付 webhook 和复杂风控。

必须完成：
1. repo 根目录新增 license-server 独立服务。
2. license-server 使用 TypeScript + Fastify + PostgreSQL + Prisma。
3. 实现 Prisma schema、migration、docker-compose、.env.example、README。
4. 实现 Admin CLI：license:create、license:list、license:add-seats、license:revoke、license:deactivate-device、license:rotate-code。
5. 实现 API：activate、refresh/challenge、refresh、deactivate、recover 安全占位。activate 必须包含 `PromptStudio-Activate-Proof-v1` device proof；ActivateProofNonce 只能在 proof 验签成功后原子消费，签名失败不得消费 nonce。
6. 实现服务端签名 license certificate。Ed25519 私钥必须使用 PKCS8 DER base64；客户端公钥必须使用 raw 32 bytes base64url；Node 和 Swift 测试必须共用同一组 fixture；不得把 private key 放入客户端。
7. macOS 客户端实现 LicenseManager、TrialManager、DeviceIdentityManager、KeychainLicenseStore、LicenseCertificateVerifier、LicenseAPIClient、FeatureGate、License 设置页、激活弹窗、当前设备停用。
8. 接入现有核心功能 Pro Gate。接入前必须生成 `docs/license_feature_gate_inventory.md`，逐项列出现有 UI 入口、菜单/快捷键入口、服务层入口和 gate 状态；不得只隐藏按钮而漏掉服务层。
9. Trial/Pro/Grace 允许 Pro 功能；TrialExpired/Limited/Revoked 只允许 Base 安全能力。
10. 授权无效时不得锁死、删除、遮挡用户已有数据，必须保留打开、查看、基础搜索、复制、基础导出能力。
11. 不上传 Prompt 正文、标题、标签名、集合名、文件名、本地路径、图片、视频、API Key、剪贴板内容。
12. 完成后输出变更文件列表、本地启动方式、创建测试 license 方式、端到端激活步骤、测试结果和剩余风险。
```

---

## 28. 一句话总结

PromptStudio Phase 1 授权系统的最优实现是：

```text
当前 repo 中新增独立 license-server，使用购买邮箱 + 激活码激活；客户端生成 installId 和设备密钥对；服务端用 PKCS8 DER Ed25519 private key 签发授权证书；activate proof nonce 只在验签成功后消费；客户端存 Keychain 并离线验签；30 天试用、30 天证书、14 天宽限；每个 license 默认 2 台设备；当前设备可停用；所有现有 Pro 功能通过 FeatureGate，并用 inventory 防止漏 gate；授权无效也必须允许用户打开、搜索、复制和基础导出已有数据。
```
