# PromptStudio 商业授权全链路设计

## 目标

为个人购买者提供可投入生产的永久授权闭环：Lemon Squeezy 支付成功后自动发证和发送邮件；用户能在 macOS App 内完成激活、席位替换、邮件找回、设备管理与授权刷新。所有失败路径必须可恢复，不阻塞本地资料的基础查看、复制与导出。

## 已确认产品决策

- 客户端采用单一“状态驱动授权中心”，不使用多层 Sheet 或独立向导。
- 支付层使用 provider-neutral 事件核心，首接 Lemon Squeezy。
- 第一版只销售永久授权；购买版本永久可用，并包含购买日起 365 天更新权益。
- 邮件使用 Resend；找回使用 15 分钟一次性邮件链接。
- 事件可靠性使用 PostgreSQL Inbox/Outbox，不引入外部消息队列。
- 生产域名为 `https://license.promptstudio.app`；默认部署方案为 Railway + PostgreSQL。

## 用户流程与 UI

### 购买与首次激活

1. App 的“购买 Pro”打开 `https://promptstudio.app/pricing`，站点进入 Lemon Squeezy Checkout。
2. 支付成功后，服务端自动创建授权并发送包含激活码、席位数、下载入口和支持入口的邮件。
3. App 授权中心默认显示邮箱、激活码两个字段，支持粘贴、回车提交和明确的字段级错误。
4. 提交时保留输入并显示进度；成功后同一窗口切换到授权摘要，使用全局 Toast 确认 Pro 已解锁。

### 席位已满

- 服务端只在邮箱和激活码校验通过后返回设备摘要。
- 授权中心原地切换到设备选择状态，展示设备名、平台、最近在线时间和当前席位数。
- 用户选择旧设备后执行“替换并激活”；服务端在同一事务中停用旧设备并创建本机激活，避免席位中间态。
- 返回按钮恢复原输入，不要求重新填写邮箱或激活码。

### 邮件找回

- 用户只输入购买邮箱；接口始终返回相同成功文案，避免泄露邮箱是否存在。
- 有效购买者收到 15 分钟一次性链接。HTTPS 恢复页读取 URL fragment 中的令牌，尝试打开 `promptstudio://license/recover`；不能打开 App 时允许复制同一个一次性恢复码。
- App 收到令牌后打开授权中心并验证当前设备。席位已满时复用同一设备替换状态；成功前不消费恢复令牌。
- 找回不会轮换永久激活码，也不会在日志、URL query 或数据库中保存明文恢复令牌。

### 已激活与长期管理

- 设置页显示方案、当前设备、席位占用、证书刷新状态和更新权益截止日。
- “管理设备”在同一授权中心切换状态，支持重命名和移除设备；移除当前设备必须二次确认。
- 证书每 7 天建议刷新、30 天到期、14 天离线宽限。网络失败保留本地有效证书；退款或撤销在下一次成功刷新时生效。
- 更新权益到期不影响当前 major 版本和本地资料；第一版只展示权益信息，不实现自动更新器。

## 服务端架构

### 商业事件

- `POST /v1/webhooks/lemonsqueezy` 使用原始 body 与 `X-Signature` 做 HMAC-SHA256 常量时间校验。
- Inbox 唯一键为 `provider + eventName + SHA256(rawBody)`；Webhook 验签并落库后立即返回 200，后台 Worker 处理事件。
- Lemon Squeezy variant 通过启动配置映射为 `plan`、`seatLimit`、`majorVersion` 和 `updatesDays=365`。未知 variant 进入失败队列并报警，不创建错误授权。
- `order_created` 幂等创建授权和购买邮件 Outbox；全额 `order_refunded` 标记授权为 `refunded`，部分退款只记录审计事件。

### 邮件与隐私

- Customer 增加版本化 AES-GCM 邮箱密文；现有 `emailHash` 用于查找，`emailMasked` 用于展示。
- 购买邮件和恢复邮件写入 EmailOutbox。包含明文激活码或恢复令牌的 payload 使用 AES-GCM 加密；Resend 接收成功后清空敏感 payload。
- Resend 请求使用稳定幂等键；投递、延迟、退信和失败 Webhook 更新 Outbox 状态，后台支持重试。
- 应用日志继续屏蔽激活码、签名、恢复令牌、邮箱和加密 payload。

### 激活与恢复接口

- `POST /v1/licenses/activate` 增加可选 `replaceActivationId`；席位满返回结构化 `SEAT_LIMIT_EXCEEDED` 数据。
- `POST /v1/licenses/recover` 接受邮箱并恒定返回 200；有效邮箱创建 RecoveryToken 哈希和邮件 Outbox。
- `POST /v1/licenses/recovery/activate` 接受一次性令牌、设备证明及可选 `replaceActivationId`；成功后原子消费令牌。
- API 错误统一为 `{ ok:false, error:{ code, message, data? }, requestId }`，客户端不展示服务地址、堆栈或解码错误。

## 客户端结构

- `LicenseAPIClient` 解码统一错误数据、区分无网络、超时、限流、服务不可用和业务错误，并为激活请求设置合理超时。
- `ActivationViewModel` 改为显式状态机：`form`、`validating`、`seatConflict`、`recoveryForm`、`recoverySent`、`recovering`、`activated`、`managingDevices`。
- `LicenseSettingsView` 与功能门控统一打开同一个授权中心；已激活用户直接进入摘要，未激活用户进入表单。
- `Info.plist` 注册 `promptstudio` URL scheme；App 路由先识别恢复 URL，再处理外部文件，避免把恢复令牌当文件导入。
- 所有按钮具有完整 hover、按压、禁用和键盘焦点；关闭热区为完整圆形。错误就近显示，成功使用现有通用 Toast。

## 运营、安全与失败处理

- Worker 使用数据库租约、最大尝试次数和指数退避；失败事件可从后台重放，不能靠重新发送支付 Webhook 修复。
- 恢复请求按 IP 与邮箱 HMAC 限流；令牌只存 SHA-256 哈希、单次使用、15 分钟过期。
- 设备替换必须重新验证邮箱/激活码或有效恢复令牌，且只能替换同一 License 下的 active Activation。
- 生产必须使用 HTTPS、独立签名密钥、数据加密密钥和 Resend/Lemon Squeezy Webhook Secret；缺失关键配置时服务启动失败。
- 管理后台展示订单、邮件、激活和失败事件，但不展示完整邮箱、激活码、恢复令牌或设备公钥。

## 验收标准

- 支付事件重复投递不会创建重复授权或重复邮件。
- 邮件临时失败可自动重试；退信在后台可见。
- 正常激活、席位替换、邮件恢复、刷新、重命名和停用设备均可从 App 完成。
- 快速重试、断网、服务端 5xx、限流和 App 重启不会丢失有效本地授权或用户输入。
- 未授权或授权异常时，已有资料的查看、复制、基础搜索、基础导出和删除仍可用。
- macOS、服务端和数据库测试全部通过，Release App 可连接本地集成环境完成端到端体验。
