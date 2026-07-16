# PromptStudio License 钥匙串 B 方案设计

日期：2026-07-16  
状态：待用户书面规格确认  
范围：macOS 客户端 License 恢复；不修改资料库、服务端协议或订阅计费逻辑

## 1. 背景与结论

当前 Mac 留有 7 条由旧版 PromptStudio 分别写入的 Generic Password 记录。每条记录都有独立的 macOS Keychain ACL，并绑定旧 ad-hoc 构建的 CDHash。当前 Debug 包重新构建后身份变化，Security.framework 因此逐项显示授权密码框。

现有实现还错误地将 `kSecReturnData` 与 `kSecMatchLimitAll` 用于密码项。Apple 明确禁止该组合，真实系统返回 `errSecParam (-50)`，导致“打开授权设置”进入不可恢复状态。

用户已选择 B 方案：不访问旧 License 秘密，不删除或覆盖旧记录，建立新的单一 License Vault，然后重新激活。资料库与其中全部资源不属于本流程，必须保持原样。

## 2. 成功标准

- B 方案执行期间，对旧 service `com.creatigo.promptstudio.license` 和旧 `v2...v16` Vault 不进行秘密读取、更新或删除。
- 不再显示 7 个连续密码框；B 方案本身不需要读取旧钥匙串密码。
- 新 License 数据只存放在一个随机命名的 Vault 项中。
- 旧 License 记录完整保留，便于诊断或人工恢复。
- 新 Vault 创建失败时不切换当前 Vault，不产生半完成状态。
- B 方案不会重新发放本地 30 天试用；完成后必须重新激活。
- `/Users/guruocen/Documents/PromptStudio Library` 的路径、数据库和资源文件不发生变化。
- FeatureDenied 弹框不再直接启动旧记录迁移，只进入恢复选择页。

## 3. 恢复选择

授权设置页在检测到旧身份或旧签名 Vault 时提供两个入口：

1. `保留并迁移旧 License`
   - 明确告知 macOS 可能逐项请求多个历史记录的授权。
   - 用户主动选择后才允许交互式读取。
   - 不自动重试，不删除旧记录。

2. `创建新的 License 身份`（B 方案，推荐）
   - 明确告知不读取或删除旧 License。
   - 二次确认后创建新 Vault。
   - 不重新开始试用，随后进入激活页。

B 方案确认文案：

> 不读取或删除旧 License，不影响本地资料库。原激活和试用不会复制，需要联网重新激活，并且不会获得新的试用期。

## 4. 单一 Vault 与定位器

### 4.1 Vault 引用

每次 B 方案生成随机 UUID，服务名格式为：

```text
com.creatigo.promptstudio.license.vault.<uuid>
```

账户名继续使用 `promptstudio.licenseVault`。随机名称确保新建流程不会查询或碰撞任何旧 Vault。

### 4.2 非敏感定位器

使用可注入的 `LicenseVaultLocatorStore` 保存 `pending` 与 `active` 引用。默认实现把两者编码为一个 `LicenseVaultLocatorState`，通过一次 UserDefaults `Data` 写入完成状态切换；引用仅包含版本、UUID、service 和 account，不包含 License、设备私钥或用户资料。

写入顺序必须为：

1. 写入 `pending` 引用。
2. 使用 `SecItemAdd` 新建随机 Vault。
3. 只读取刚创建的随机 service，校验内容一致。
4. 将该引用原子提升为 `active`。
5. 清除 `pending`。

若第 2 至第 4 步失败，`active` 不变；新产生的孤立随机 Vault 保留，不扫描、不复用，也不删除旧记录。重启时忽略并清理无效的 `pending` 定位器。

一旦存在 `active` 引用，启动时只读取该 Vault，不再扫描旧 service 或旧代际。active 对应项缺失、损坏或需要旧签名授权时，客户端必须 fail closed，进入恢复选择，不得自动创建试用。

## 5. 恢复墓碑与试用保护

新 Vault 初始只写入 `licenseRecoveryMarker`：

```swift
struct LicenseRecoveryMarker: Codable, Equatable {
    let version: Int
    let mode: Mode
    let createdAt: Date
    let blocksTrialBootstrap: Bool

    enum Mode: String, Codable {
        case newIdentity
        case migratedExisting
    }
}
```

B 方案使用 `mode = .newIdentity` 和 `blocksTrialBootstrap = true`。

本地没有授权证书时，LicenseManager 先检查恢复墓碑：

- 墓碑阻止试用：状态为 `reactivationRequiredAfterKeychainRecovery`。
- 没有墓碑且可证明为普通首次安装：才允许 TrialManager 创建首次试用。

激活成功后墓碑继续保留。以后证书缺失、停用或激活失败时，也不能回退到新试用。

## 6. 客户端状态与接口

新增恢复选项与状态：

```swift
enum LicenseRecoveryOption {
    case preserveAndMigrate
    case newIdentityAndReactivate
}

enum LicenseRecoveryPhase {
    case notRequired
    case choiceRequired
    case working(LicenseRecoveryOption)
    case reactivationRequired
    case completed
    case failed
}
```

Store 使用两个独立接口，禁止用布尔参数混合两条路径：

```swift
func migrateExistingLicense(using context: LAContext) throws
func createFreshVaultForReactivation(now: Date) throws
```

`createFreshVaultForReactivation` 不得调用 `prepareForBackgroundAccess`、`readPreferredVault`、旧 Vault 扫描或旧值读取。它只允许：生成随机引用、写 pending、添加新 Vault、校验新 Vault、提交 active。

LicenseManager 对外提供：

```swift
func recoverLicense(using option: LicenseRecoveryOption) throws
```

B 方案成功后状态立即变为需要重新激活，授权设置页自动进入激活流程。

## 7. 错误处理

- `errSecInteractionNotAllowed (-25308)`、`errSecInteractionRequired (-25315)` 以及后台 `errSecAuthFailed (-25293)` 映射为可恢复状态。
- 其他错误使用 `SecCopyErrorMessageString` 加 OSStatus 数字展示，不再只显示 `-50`。
- 用户取消 A 方案后保持恢复选择状态，不自动重试。
- B 方案 Locator 提交失败时，不把新 Vault 设为 active。
- 任何 License 恢复失败都不影响资料库浏览、搜索、复制和基础导出。

## 8. 签名约束

B 方案解决旧 7 条记录和当前死循环，但不能替代正式签名。当前机器没有可用 Developer ID，Debug 包仍为 ad-hoc；每次重新构建会改变 CDHash。

发布与长期 QA 必须使用固定 Team ID 的 Developer ID 签名及稳定 designated requirement。最终签名后，新单一 Vault 才能跨版本持续无提示访问。ad-hoc 仅用于开发，不得作为售卖包。

## 9. 测试与验收

### 9.1 自动化

- Generic Password 查询永不组合 `kSecReturnData + kSecMatchLimitAll`。
- B 方案对 legacy service 和 `v2...v16` 的秘密 read/update/delete 次数为 0。
- B 方案仅对随机新 service 执行一次 Add 和一次校验读取。
- Locator 提交前失败时 active 不变。
- B 方案结束后为重新激活状态，不创建 Trial。
- 重启后仍读取同一个 active Vault，并保持重新激活状态。
- 旧项数量和内容不变。
- A 方案只能由用户操作触发，后台启动与 FeatureGate 不会自动开始迁移。

### 9.2 本机 UI

- 启动正确迁移项目 Debug App，后台不出现钥匙串密码框。
- 点击 Pro 功能后只出现恢复说明，不直接读取旧 License。
- 选择 B 并二次确认后，不出现 7 个密码框，直接进入激活页。
- SQLite 仍为 `/Users/guruocen/Documents/PromptStudio Library/database/promptstudio.sqlite`。
- UI 仍显示 280 条有效资源和回收站 10 条，共 290 条。

### 9.3 发布前

- 用相同 Developer ID 连续构建两个 App，第二个 App 访问同一 Vault 时为 0 次授权提示。
- `codesign --verify --deep --strict` 通过，Team ID 与 designated requirement 固定。
- 真实 macOS 测试账号验证 A 方案的逐项授权提示只发生在主动迁移流程内。

## 10. 非目标

- 不删除旧 License 项。
- 不读取、迁移或修改 PromptStudio 资料库内容。
- 不修改 License 服务端激活协议、席位规则或订阅计费。
- 不把本地恢复当作商业级防刷试用方案；服务端 Trial Receipt 或账号级试用台账属于后续独立项目。
