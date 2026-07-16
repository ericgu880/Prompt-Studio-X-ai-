# License Keychain B Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken seven-item Keychain recovery path with a non-destructive B flow that creates one randomly named Vault without reading old License secrets, blocks trial reset, and routes the user to reactivation.

**Architecture:** A small recovery model owns the non-secret active/pending Vault locator in UserDefaults. `KeychainLicenseStore` uses the locator to read exactly one active Vault and writes B recovery through `pending → SecItemAdd → verify → active`; the new Vault contains a recovery marker that prevents Trial bootstrap. Existing legacy preservation remains an explicit user-triggered path, while FeatureGate only opens the recovery choice UI.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftUI/AppKit, Security.framework, LocalAuthentication, UserDefaults, existing standalone License regression harness.

---

## File map

- Create `Sources/PromptStudio/License/LicenseVaultRecovery.swift`: recovery options, marker, Vault reference, locator state/protocol, UserDefaults locator.
- Modify `Sources/PromptStudio/License/KeychainLicenseStore.swift`: valid legacy discovery, status classification, active locator reads, random B Vault creation, no-old-secret invariant.
- Modify `Sources/PromptStudio/License/LicenseManager.swift`: recovery state machine and B transition to reactivation-required.
- Modify `Sources/PromptStudio/License/LicenseState.swift`: recovery-specific limited reason and actions.
- Modify `Sources/PromptStudio/License/FeatureGate.swift`: recovery choice messaging and activation routing.
- Modify `Sources/PromptStudio/License/LicenseSettingsView.swift`: two explicit recovery choices and B confirmation.
- Modify `Scripts/test_license_keychain.sh`: compile the new recovery source.
- Modify `Tests/LicenseKeychainRegressionTests/main.swift`: Security query, locator atomicity, no legacy access, no Trial reset, and UI-decision logic regressions.
- Modify `TESTING.md`: document B recovery and stable-signing manual acceptance.

### Task 1: Add the recovery model and atomic locator

**Files:**
- Create: `Sources/PromptStudio/License/LicenseVaultRecovery.swift`
- Modify: `Scripts/test_license_keychain.sh`
- Test: `Tests/LicenseKeychainRegressionTests/main.swift`

- [ ] **Step 1: Write the failing locator round-trip test**

Add an in-memory locator test double and a test that stores pending and active state as one value:

```swift
private final class RecordingVaultLocator: LicenseVaultLocatorStore {
    var stored = LicenseVaultLocatorState()
    private(set) var saves: [LicenseVaultLocatorState] = []
    var failOnSaveNumber: Int?

    func load() throws -> LicenseVaultLocatorState { stored }

    func save(_ state: LicenseVaultLocatorState) throws {
        let saveNumber = saves.count + 1
        if failOnSaveNumber == saveNumber {
            failOnSaveNumber = nil
            throw RecordingStoreFailure(message: "injected locator failure")
        }
        stored = state
        saves.append(state)
    }
}

private static func vaultLocatorRoundTripsOneAtomicState() throws {
    let locator = RecordingVaultLocator()
    let reference = LicenseVaultReference(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        service: "com.creatigo.promptstudio.license.vault.11111111-1111-1111-1111-111111111111",
        account: "promptstudio.licenseVault"
    )
    try locator.save(LicenseVaultLocatorState(active: nil, pending: reference))
    try locator.save(LicenseVaultLocatorState(active: reference, pending: nil))
    guard try locator.load().active == reference,
          locator.saves.count == 2 else {
        throw Failure("Vault locator must persist pending and active as one atomic state")
    }
}
```

- [ ] **Step 2: Run the regression harness and verify RED**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: compilation fails because `LicenseVaultLocatorStore`, `LicenseVaultLocatorState`, and `LicenseVaultReference` do not exist.

- [ ] **Step 3: Create the recovery model**

Create `LicenseVaultRecovery.swift` with these exact responsibilities:

```swift
import Foundation

enum LicenseRecoveryOption: Equatable, Sendable {
    case preserveAndMigrate
    case newIdentityAndReactivate
}

enum LicenseRecoveryPhase: Equatable {
    case notRequired
    case choiceRequired
    case working(LicenseRecoveryOption)
    case reactivationRequired
    case completed
    case failed(option: LicenseRecoveryOption, message: String)
}

struct LicenseRecoveryMarker: Codable, Equatable {
    enum Mode: String, Codable { case migratedExisting, newIdentity }
    let version: Int
    let mode: Mode
    let createdAt: Date
    let blocksTrialBootstrap: Bool
}

struct LicenseVaultReference: Codable, Equatable, Sendable {
    let id: UUID
    let service: String
    let account: String
}

struct LicenseVaultLocatorState: Codable, Equatable {
    var active: LicenseVaultReference?
    var pending: LicenseVaultReference?

    init(active: LicenseVaultReference? = nil, pending: LicenseVaultReference? = nil) {
        self.active = active
        self.pending = pending
    }
}

protocol LicenseVaultLocatorStore: AnyObject {
    func load() throws -> LicenseVaultLocatorState
    func save(_ state: LicenseVaultLocatorState) throws
}

final class UserDefaultsLicenseVaultLocator: LicenseVaultLocatorStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "PromptStudioLicenseVaultLocatorState.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> LicenseVaultLocatorState {
        guard let data = defaults.data(forKey: key) else { return LicenseVaultLocatorState() }
        return try decoder.decode(LicenseVaultLocatorState.self, from: data)
    }

    func save(_ state: LicenseVaultLocatorState) throws {
        defaults.set(try encoder.encode(state), forKey: key)
    }
}
```

Add `LicenseVaultRecovery.swift` immediately before `KeychainLicenseStore.swift` in `Scripts/test_license_keychain.sh`.

- [ ] **Step 4: Run the regression harness and verify GREEN**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: `License keychain regression tests passed`.

### Task 2: Correct legacy discovery and Security error classification

**Files:**
- Modify: `Sources/PromptStudio/License/KeychainLicenseStore.swift`
- Test: `Tests/LicenseKeychainRegressionTests/main.swift`

- [ ] **Step 1: Preserve the failing macOS parameter regression**

Keep `legacyDiscoveryAvoidsUnsupportedBulkPasswordData()` and make the fake backend return `errSecParam` whenever a generic-password query combines:

```swift
if attributes[kSecReturnData as String] as? Bool == true,
   attributes[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
    return errSecParam
}
```

- [ ] **Step 2: Verify RED against the pre-fix implementation**

Run: `bash Scripts/test_license_keychain.sh`  
Expected before production correction: failure message `generic-password discovery cannot combine kSecReturnData with kSecMatchLimitAll`.

- [ ] **Step 3: Implement attribute-only discovery and individual reads**

Use one cached discovery followed by account-specific reads:

```swift
private func discoverLegacyKeys() throws -> [Key] {
    var query = itemQuery(service: legacyService, account: nil)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = copyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    try check(status)
    let items = (result as? [Any]) ?? (result.map { [$0] } ?? [])
    let found = Set(items.compactMap { item -> Key? in
        guard let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String else { return nil }
        return Key(rawValue: account)
    })
    return Key.allCases.filter(found.contains)
}

private func readAllLegacyValues() throws -> [String: Data] {
    let keys: [Key]
    if let discoveredLegacyKeys {
        keys = discoveredLegacyKeys
    } else {
        keys = try discoverLegacyKeys()
    }
    var values: [String: Data] = [:]
    for key in keys {
        if let value = try readItem(itemQuery(service: legacyService, account: key.rawValue)) {
            values[key.rawValue] = value
        }
    }
    return values
}
```

`prepareForBackgroundAccess()` must discover names only and throw `keychainAccessRequired` when any old key exists.

- [ ] **Step 4: Classify recoverable statuses and expose real messages**

Implement:

```swift
private func check(_ status: OSStatus) throws {
    if status == errSecInteractionNotAllowed
        || status == errSecInteractionRequired
        || (status == errSecAuthFailed && interactiveContext == nil) {
        throw LicenseError.keychainAccessRequired
    }
    guard status == errSecSuccess else {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "未知 Keychain 错误"
        throw LicenseError.keychain("\(message)（OSStatus \(status)）")
    }
}
```

- [ ] **Step 5: Run the regression harness**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: `License keychain regression tests passed`.

### Task 3: Create a random B Vault without touching old secrets

**Files:**
- Modify: `Sources/PromptStudio/License/KeychainLicenseStore.swift`
- Test: `Tests/LicenseKeychainRegressionTests/main.swift`

- [ ] **Step 1: Write strict operation-boundary tests**

Extend the fake Keychain backend to record service, operation, and whether data was requested. Add a test that snapshots operations immediately before B recovery and asserts the delta:

```swift
let forbiddenLegacyServices = Set((2...16).map { "com.creatigo.promptstudio.license.v\($0)" })
let before = backend.operations.count
try store.createFreshVaultForReactivation(now: fixedDate)
let delta = Array(backend.operations.dropFirst(before))
guard delta.filter({ $0.service == "com.creatigo.promptstudio.license" }).isEmpty,
      delta.filter({ forbiddenLegacyServices.contains($0.service) }).isEmpty,
      delta.map(\.operation) == [.add, .copyData] else {
    throw Failure("B recovery may only add and verify its random Vault")
}
```

Also assert the generated service starts with `com.creatigo.promptstudio.license.vault.` and the two old legacy items remain byte-for-byte equal.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: failure because the current prototype scans `v2...v16` before creating a Vault.

- [ ] **Step 3: Inject the locator and UUID generator**

Extend the initializer without changing production call sites:

```swift
init(
    copyMatching: @escaping CopyMatching = SecItemCopyMatching,
    update: @escaping Update = SecItemUpdate,
    add: @escaping Add = SecItemAdd,
    locator: any LicenseVaultLocatorStore = UserDefaultsLicenseVaultLocator(),
    makeUUID: @escaping () -> UUID = UUID.init
) {
    self.copyMatching = copyMatching
    self.update = update
    self.add = add
    self.locator = locator
    self.makeUUID = makeUUID
    let context = LAContext()
    context.interactionNotAllowed = true
    self.backgroundContext = context
}
```

- [ ] **Step 4: Add the recovery marker key and random Vault write**

Add `case licenseRecoveryMarker = "promptstudio.licenseRecoveryMarker"` to `Key` and implement:

```swift
func createFreshVaultForReactivation(now: Date) throws {
    let id = makeUUID()
    let reference = LicenseVaultReference(
        id: id,
        service: "com.creatigo.promptstudio.license.vault.\(id.uuidString.lowercased())",
        account: vaultAccount
    )
    let marker = LicenseRecoveryMarker(
        version: 1,
        mode: .newIdentity,
        createdAt: now,
        blocksTrialBootstrap: true
    )
    let markerData = try JSONEncoder().encode(marker)
    let vault = Vault(
        migrationVersion: Self.currentMigrationVersion,
        values: [Key.licenseRecoveryMarker.rawValue: markerData]
    )

    var locatorState = try locator.load()
    locatorState.pending = reference
    try locator.save(locatorState)
    try addNewVaultAndVerify(vault, reference: reference)
    locatorState.active = reference
    locatorState.pending = nil
    try locator.save(locatorState)
    preferredVaultService = reference.service
    discoveredLegacyKeys = []
    confirmedNoLegacyItems = true
}
```

`addNewVaultAndVerify` must call `SecItemAdd` directly, then read only the random service and compare decoded Vault contents. It must never call `SecItemUpdate` or any legacy discovery method.

Replace the prototype `startFreshAuthorizationVault(expiredTrialStartedAt:)` protocol requirement with `createFreshVaultForReactivation(now:)`, and update every `LicenseStore` test double to conform. Remove the expired-1970 Trial workaround; the recovery marker is the only Trial-blocking mechanism.

- [ ] **Step 5: Make active-locator startup fail closed**

At the start of `readPreferredVault()` load the locator. If `active` exists, read only its service. Return it when valid; if missing or corrupt, throw `keychainVaultCorrupted` and do not scan old generations. If no active exists, retain legacy discovery for migration compatibility. Clear a stale `pending` field with one locator-state save before normal startup.

- [ ] **Step 6: Add locator failure and restart tests**

Cover:

```swift
locator.failOnSaveNumber = 2
do {
    try store.createFreshVaultForReactivation(now: fixedDate)
    throw Failure("injected locator failure must abort recovery")
} catch is RecordingStoreFailure {}
guard locator.stored.active == nil else {
    throw Failure("failed recovery must not publish an active Vault")
}
```

Then create a fresh store with the same locator and assert it reads only the active random Vault and preserves the marker after restart.

- [ ] **Step 7: Run the regression harness**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: `License keychain regression tests passed`.

### Task 4: Block Trial restart and expose recovery state

**Files:**
- Modify: `Sources/PromptStudio/License/LicenseManager.swift`
- Modify: `Sources/PromptStudio/License/LicenseState.swift`
- Modify: `Sources/PromptStudio/License/FeatureGate.swift`
- Test: `Tests/LicenseKeychainRegressionTests/main.swift`

- [ ] **Step 1: Write failing Manager and FeatureGate tests**

Add tests that expect B recovery to produce `.limited(reason: .reactivationRequiredAfterKeychainRecovery)`, keep `interactiveRuns == 0`, and produce `.activate` as the Pro-feature action. Also remove the prototype expectation of `.trialExpired`.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: failure because the recovery-specific limited reason does not exist.

- [ ] **Step 3: Add recovery state and user-facing text**

Add:

```swift
case reactivationRequiredAfterKeychainRecovery
```

to `LimitedReason`, with description:

```swift
"已建立新的 License 身份；原激活和试用未复制，请重新激活。"
```

Add `case chooseKeychainRecovery` to `UpgradeAction`. Map `.keychainAccessRequired` to the recovery-choice action and the new limited reason to `.activate`.

- [ ] **Step 4: Implement Manager recovery without Trial bootstrap**

Add `@Published private(set) var recoveryPhase: LicenseRecoveryPhase = .notRequired` and implement:

```swift
func recoverLicense(using option: LicenseRecoveryOption) throws {
    _ = beginMutation()
    recoveryPhase = .working(option)
    do {
        switch option {
        case .preserveAndMigrate:
            let context = LAContext()
            context.localizedReason = "读取并保留这台 Mac 上现有的 PromptStudio License"
            try store.withInteractiveAuthentication(context: context) {
                try store.migrateLegacyItemsToVault()
            }
            try store.prepareForBackgroundAccess()
            state = try resolveLocalState()
            recoveryPhase = .completed
        case .newIdentityAndReactivate:
            try store.createFreshVaultForReactivation(now: Date())
            state = .limited(reason: .reactivationRequiredAfterKeychainRecovery)
            recoveryPhase = .reactivationRequired
        }
    } catch {
        recoveryPhase = .failed(option: option, message: error.localizedDescription)
        throw error
    }
}
```

In `resolveLocalState`, after checking revocation/certificate and before calling TrialManager, decode `licenseRecoveryMarker`; when `blocksTrialBootstrap` is true return the recovery-specific limited state.

In `loadStateOnLaunch`, set `recoveryPhase = .choiceRequired` whenever background preparation throws `keychainAccessRequired`. After a successful activation, set a previous `.reactivationRequired` phase to `.completed`; activation failure must leave the marker and reactivation-required state intact.

- [ ] **Step 5: Run the regression harness**

Run: `bash Scripts/test_license_keychain.sh`  
Expected: `License keychain regression tests passed`.

### Task 5: Replace direct repair with a recovery choice UI

**Files:**
- Modify: `Sources/PromptStudio/License/LicenseSettingsView.swift`

- [ ] **Step 1: Add the B confirmation state and recovery row**

Add `@State private var confirmsFreshLicenseIdentity = false`. In the Keychain recovery row show two buttons:

```swift
Button(isRepairingKeychain ? "迁移中" : "保留并迁移") {
    recover(.preserveAndMigrate)
}
.disabled(isRepairingKeychain)

Button("创建新身份") {
    confirmsFreshLicenseIdentity = true
}
.buttonStyle(CapsuleButtonStyle(filled: true))
```

Use this detail text:

```text
旧 License 由 macOS 分别保护。保留迁移可能出现多个系统授权框；创建新身份不会读取旧记录，需要重新激活。
```

- [ ] **Step 2: Add the non-destructive confirmation dialog**

Attach:

```swift
.confirmationDialog(
    "创建新的 License 身份？",
    isPresented: $confirmsFreshLicenseIdentity
) {
    Button("保留旧记录并重新激活") {
        recover(.newIdentityAndReactivate)
    }
    Button("取消", role: .cancel) {}
} message: {
    Text("不读取或删除旧 License，不影响本地资料库。原激活和试用不会复制，需要联网重新激活，并且不会获得新的试用期。")
}
```

On B success set `route = .activation(recoveryToken: nil)` and show `新的 License 身份已建立，请重新激活`.

- [ ] **Step 3: Make FeatureDenied open settings only**

For `.chooseKeychainRecovery`, show one `选择恢复方式` button that calls `state.openLicenseSettings()`. Remove direct migration from `FeatureDeniedSheet`; only the explicit settings choice may touch legacy secrets.

- [ ] **Step 4: Build the app**

Run: `swift build` through `Scripts/swift_toolchain.sh` or `bash Scripts/build_app.sh debug`.  
Expected: build succeeds with no Swift errors.

### Task 6: Complete automated and static verification

**Files:**
- Modify: `TESTING.md`
- Test: `Tests/LicenseKeychainRegressionTests/main.swift`

- [ ] **Step 1: Add recovery documentation**

Document that B recovery never reads/deletes legacy items, does not restart Trial, and requires activation. State that ad-hoc Debug signatures are not stable and final acceptance requires Developer ID.

- [ ] **Step 2: Run focused gates**

Run:

```bash
bash Scripts/test_license_keychain.sh
bash Scripts/test_codesign_policy.sh
```

Expected: both suites pass.

- [ ] **Step 3: Run project gates**

Run:

```bash
source Scripts/swift_toolchain.sh
SWIFT_BUILD_EXEC="$(find_compatible_swift_tool swift)"
"$SWIFT_BUILD_EXEC" build
"$SWIFT_BUILD_EXEC" test
"$SWIFT_BUILD_EXEC" run PromptStudioCoreUnitTests
"$SWIFT_BUILD_EXEC" run PromptStudioSmokeTests
```

Expected: all available suites pass. Any environment-only skip must be reported with the exact reason.

- [ ] **Step 4: Run repository hygiene checks**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intended tracked files plus the user's pre-existing untracked files.

### Task 7: Rebuild, apply B locally, and verify the correct library

**Files:**
- Build output: `.build/arm64-apple-macosx/debug/PromptStudio.app`

- [ ] **Step 1: Build the final Debug bundle once**

Run: `bash Scripts/build_app.sh debug`  
Expected: prints the exact migration-project Debug App path and passes Debug signing verification.

- [ ] **Step 2: Quit only the current PromptStudio process and open the rebuilt bundle**

Target only the executable beneath the migration project. Do not open or search for other PromptStudio packages.

- [ ] **Step 3: Verify startup does not display Keychain UI**

Observe the UI and `securityd` logs. Expected: background startup shows no SecurityAgent password dialog and Pro actions lead to `选择恢复方式`.

- [ ] **Step 4: Execute the user-approved B action**

Through the settings UI choose `创建新身份`, accept the B confirmation, and confirm that no legacy Keychain password dialog appears. Expected: activation page opens.

- [ ] **Step 5: Verify database and resource counts**

Run `lsof` on the final PromptStudio PID. Expected open database:

```text
/Users/guruocen/Documents/PromptStudio Library/database/promptstudio.sqlite
```

UI must show 280 active resources and 10 trash resources. Run SQLite integrity and foreign-key checks; expected `ok` and no foreign-key rows.

### Task 8: Review, commit, and push

**Files:**
- All intended source, test, documentation, and plan files above

- [ ] **Step 1: Run pre-landing review**

Inspect the full diff for security regressions, Trial reset paths, accidental old-item deletion, UI dead ends, and unrelated changes.

- [ ] **Step 2: Commit only intended files**

Run:

```bash
git add Sources/PromptStudio/License/LicenseVaultRecovery.swift \
  Sources/PromptStudio/License/KeychainLicenseStore.swift \
  Sources/PromptStudio/License/LicenseManager.swift \
  Sources/PromptStudio/License/LicenseState.swift \
  Sources/PromptStudio/License/FeatureGate.swift \
  Sources/PromptStudio/License/LicenseSettingsView.swift \
  Scripts/test_license_keychain.sh \
  Tests/LicenseKeychainRegressionTests/main.swift \
  TESTING.md \
  docs/superpowers/plans/2026-07-16-license-keychain-b-recovery.md
git commit -m "fix(license): replace repeated keychain prompts"
```

Do not stage the user's unrelated untracked QA documents, exports, images, or DOCX.

- [ ] **Step 3: Push the feature branch**

Run: `git push origin codex/license-commercial-flow`  
Expected: remote branch advances to the new commit.

- [ ] **Step 4: Report the immutable constraint**

Report that B recovery is complete locally, old License records were preserved, the local library remained intact, and the current Debug build is still ad-hoc because the machine has no Developer ID identity. Do not claim cross-build zero-prompt behavior until a stable Developer ID package passes the two-build acceptance test.
