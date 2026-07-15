# PromptStudio

PromptStudio 是一个 macOS 本地优先的 Prompt 与创作素材资料库。图片、视频、音频、文档、Prompt、版本和参考素材保存在用户选择的本地资料库中；商业授权服务位于 `license-server/`，私有运营后台位于同级仓库 `../promptstudio-admin`。

## 开发与验证

项目要求 Swift 6.2 或更高版本：

```bash
source Scripts/swift_toolchain.sh
SWIFT_EXEC="$(find_compatible_swift_tool swift)"
"$SWIFT_EXEC" build
"$SWIFT_EXEC" build -c release --product PromptStudio
"$SWIFT_EXEC" test
"$SWIFT_EXEC" run PromptStudioCoreUnitTests
"$SWIFT_EXEC" run PromptStudioSmokeTests
bash Scripts/test_swift_toolchain.sh
bash Scripts/test_license_keychain.sh
bash Scripts/test_codesign_policy.sh
bash Scripts/test_release_ui_copy.sh
```

授权服务：

```bash
cd license-server
npm ci
npm run prisma:generate
npm test
npm run build
```

完整测试说明见 `TESTING.md`，上线审查结论见 `docs/PRELAUNCH_READINESS_2026-07-16.md`。

## Release 打包

正式包必须使用 Developer ID Application、Hardened Runtime、时间戳和生产 Ed25519 公钥。桌面版购买链接不设默认值，防止误跳到另一套云订阅产品；只有发布流水线传入经过确认的 HTTPS 购买 URL 后，购买按钮才会开放。

```bash
LICENSE_SIGNING_KEY_ID='prod-2026-01' \
LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL='...' \
PROMPTSTUDIO_PURCHASE_URL='https://your-verified-checkout.example/...' \
SIGN_IDENTITY='Developer ID Application: ...' \
EXPECTED_TEAM_ID='ABCDE12345' \
Scripts/build_app.sh release
```

不要把许可证签名私钥放入 App、Git 或打包环境；App 只接收公钥。未配置购买 URL 时，界面会明确显示购买通道尚未开放，已有用户仍可输入激活码。

## 当前商业边界

当前实现是桌面版永久授权和设备席位；一年版本更新权益已经记录、签名并展示，但跨大版本的允许/拒绝规则仍需产品确认后由服务端执行。`LicenseType.subscription` 只是数据模型预留，尚无续费、取消、欠费、账期或订阅 webhook 状态机，不能作为已完成的订阅能力宣传或售卖。
