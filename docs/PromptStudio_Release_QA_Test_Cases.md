# PromptStudio 上线前详细测试用例

目标：用一份可执行的中文 QA 用例覆盖 PromptStudio 的核心定位：本地 Prompt、素材、文档库的存储、管理、检索、导入、导出和复用。

不测试 Prompt 生成结果，不把 PromptStudio 当成 AI 生成器测试。所有删除、恢复、批量导入、大库性能测试都必须使用测试 library，不能污染真实用户库。

## 结果口径

- 通过：实际结果符合预期。
- 失败：功能可执行，但实际结果不符合预期。
- 阻塞：环境、构建、权限、授权或数据准备问题导致无法判断。
- 跳过：本轮测试范围不包含该项，或缺少明确前置条件。

## 测试前准备

环境要求：

- macOS 15。
- Apple Silicon。
- 使用测试 library，不使用真实生产 prompt 库做破坏性测试。
- UI 破坏性测试必须用临时 library 启动 App：

```sh
Scripts/build_app.sh release
LIB="$(mktemp -d /tmp/promptstudio-ui-qa.XXXXXX)"
open .build/release/PromptStudio.app --args --library "$LIB"
```

只有在 App 设置页显示临时路径，或 `$LIB/database/promptstudio.sqlite`
等文件系统证据存在时，UI 用例才能判通过。没有证据时标记阻塞、跳过或
未知，不能假 PASS。

自动门禁：

```sh
swift build
swift test
swift run PromptStudioCoreUnitTests
swift run PromptStudioSmokeTests
```

测试文件：

- `qa-prompt.md`：包含 `Prompt:`、`Negative Prompt:`、`Tags:`、`--ar 16:9`。
- `qa-prompt.json`：包含 `prompt`、`negativePrompt`、`tags`、`parameters`。
- `qa-note.txt`：普通 prompt 文本。
- `qa-image.png`：小尺寸图片。
- 一个混合文件夹：Markdown、JSON、TXT、PNG、PDF、未知扩展文件。

## TC-001 首次启动和空库状态

前置条件：使用一个全新的空 library。

步骤：

1. 启动 PromptStudio。
2. 观察主窗口是否正常出现。
3. 检查三栏布局：侧边栏、内容区、详情 / Inspector。
4. 检查空库提示、默认分类、按钮状态。
5. 关闭 App 后重新打开。

预期结果：

- App 不崩溃。
- 空库状态文案清晰。
- 没有明显布局错位、重叠、按钮不可见。
- 重新打开后仍能正常读取同一个 library。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-002 创建 Prompt

前置条件：App 已打开，library 可写。

步骤：

1. 点击新建 Prompt。
2. 输入标题：`QA Forest Product Shot`。
3. 输入 prompt 正文：`cinematic product photo in a forest`。
4. 输入 negative prompt：`watermark, blurry`。
5. 添加 tags：`产品`、`森林`、`写实`。
6. 选择 folder：`QA Campaign`。
7. 选择或填写 model：`Image Model`。
8. 保存。

预期结果：

- 新记录出现在列表中。
- 标题、正文、negative prompt、tags、folder、model 均保存正确。
- 详情区显示和输入一致。
- 无重复空 tag、无乱码、无字段丢失。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-003 编辑 Prompt 并持久化

前置条件：存在 `QA Forest Product Shot`。

步骤：

1. 打开该 Prompt。
2. 修改正文为：`updated cinematic product photo with soft light`。
3. 修改 negative prompt 为：`watermark, text, logo`。
4. 添加 tag：`柔光`。
5. 保存。
6. 关闭 App。
7. 重新打开 App。
8. 再次打开该 Prompt。

预期结果：

- 修改后的正文仍存在。
- negative prompt 未丢失。
- 新 tag 存在。
- 原有 tags 没有异常消失。
- 重新启动后数据仍一致。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-004 版本管理

前置条件：同一个 Prompt 至少编辑过一次。

步骤：

1. 打开 Prompt 的版本历史。
2. 检查是否存在初始版本和编辑后的版本。
3. 复制历史版本内容。
4. 恢复到旧版本。
5. 再恢复到最新版本。

预期结果：

- 版本数量正确。
- 当前版本标识正确。
- 恢复旧版本后正文变为旧内容。
- 再恢复最新版本后正文恢复为新内容。
- 复制版本内容正确。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-005 搜索 Prompt 正文

前置条件：存在多个 Prompt，其中一个正文包含 `soft light`。

步骤：

1. 在搜索框输入 `soft light`。
2. 观察搜索结果。
3. 清空搜索框。

预期结果：

- 目标 Prompt 出现在结果中。
- 不包含该关键词的 Prompt 不应错误出现。
- 清空搜索后完整列表恢复。
- 搜索过程无明显卡顿。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-006 按 Tag / Folder / Model 筛选

前置条件：至少有 5 条 Prompt，分布在不同 tag、folder、model。

步骤：

1. 选择 tag：`森林`。
2. 再叠加 folder：`QA Campaign`。
3. 再叠加 model：`Image Model`。
4. 切换 favorite 筛选。
5. 清空所有筛选。

预期结果：

- 每次筛选结果都只显示符合条件的记录。
- 组合筛选逻辑正确。
- 清空筛选后列表恢复。
- 筛选状态 UI 清晰可见。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-007 收藏、最近使用、删除和恢复

前置条件：存在至少 3 条 Prompt。

步骤：

1. 收藏 `QA Forest Product Shot`。
2. 切到收藏列表。
3. 打开该 Prompt，让它进入最近使用。
4. 切到最近使用。
5. 删除该 Prompt。
6. 切到垃圾箱。
7. 恢复该 Prompt。
8. 回到全部列表。

预期结果：

- 收藏列表包含该 Prompt。
- 最近使用排序合理。
- 删除后从普通列表消失。
- 垃圾箱中能看到该 Prompt。
- 恢复后回到原列表。
- 恢复后正文、tags、folder、versions 不丢失。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-008 Folder 管理

前置条件：library 可写。

步骤：

1. 创建 folder：`QA Folder A`。
2. 创建子 folder：`QA Folder B`。
3. 将一个 Prompt 移动到 `QA Folder A`。
4. 重命名 `QA Folder A` 为 `QA Folder Renamed`。
5. 删除空 folder。
6. 尝试删除包含 Prompt 的 folder。

预期结果：

- Folder 创建成功。
- Prompt 移动后归属正确。
- 重命名后列表和详情区同步更新。
- 删除空 folder 成功。
- 删除非空 folder 时行为明确：阻止、提示或安全迁移，不应静默丢数据。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-009 导入 Markdown Prompt

前置条件：准备 `qa-prompt.md`。

步骤：

1. 通过导入入口选择 `qa-prompt.md`。
2. 导入完成后打开新记录。
3. 检查标题、prompt 正文、negative prompt、tags、parameters。
4. 删除原始 `qa-prompt.md`。
5. 重新打开 App 并查看该记录。

预期结果：

- Markdown 文件成功导入。
- prompt 正文解析正确。
- negative prompt 解析正确。
- tags 解析正确。
- 参数如 `ar=16:9` 被保留。
- 删除原文件后，App 内记录仍可访问。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-010 导入 JSON / TXT / 图片

前置条件：准备 `qa-prompt.json`、`qa-note.txt`、`qa-image.png`。

步骤：

1. 分别导入 JSON、TXT、PNG。
2. 检查每条导入记录的 type / asset kind / format。
3. 检查 JSON 的 metadata 解析。
4. 检查 TXT 的 prompt 内容。
5. 检查 PNG 的尺寸、比例、文件大小、预览图。

预期结果：

- 三类文件都能成功导入。
- JSON metadata 正确。
- TXT 内容不丢失。
- PNG 预览正常。
- 图片尺寸和比例合理。
- 不支持的字段不会导致崩溃。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-011 批量导入混合文件夹

前置条件：准备包含 Markdown、JSON、TXT、PNG、PDF、未知扩展的文件夹。

步骤：

1. 导入整个文件夹。
2. 等待导入完成。
3. 检查导入数量。
4. 逐类抽查记录 metadata。
5. 搜索导入文件中的关键词。
6. 检查不支持文件的展示方式。

预期结果：

- 支持格式全部导入。
- 不支持格式以安全占位或附件方式导入。
- 不崩溃。
- 不丢失已成功导入的文件。
- 搜索能搜到导入内容。
- 错误提示能指出失败文件。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-012 导出 Prompt Markdown

前置条件：存在一条完整 Prompt，含正文、negative prompt、tags、model、folder。

步骤：

1. 打开该 Prompt。
2. 执行导出 Markdown。
3. 选择测试目录。
4. 打开导出的 `.md` 文件。
5. 检查文件内容。

预期结果：

- 导出文件存在。
- 标题正确。
- prompt 正文完整。
- negative prompt 完整。
- tags、model、folder 或相关 metadata 保留。
- 文件编码正常，无乱码。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-013 预览和复制

前置条件：存在图片、Markdown、JSON、TXT、视频或音频样例。

步骤：

1. 选中图片，按 Space 打开预览。
2. 选中 Markdown，打开预览。
3. 选中 JSON / TXT，打开预览。
4. 复制 prompt 正文到剪贴板。
5. 粘贴到外部文本编辑器检查。

预期结果：

- Space 能打开和关闭预览。
- 图片预览正常。
- 文本文档可读。
- JSON / Markdown 高亮不影响阅读。
- 复制内容准确，不多复制 UI 文案。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-014 缩略图和缺失文件

前置条件：导入一张图片和一个外部文件。

步骤：

1. 检查图片缩略图是否生成。
2. 删除原始外部文件。
3. 回到 App 查看记录。
4. 尝试预览或导出该记录。

预期结果：

- 已归档到 library 的文件不受原始文件删除影响。
- 如果某条记录源文件确实缺失，App 应显示可理解错误。
- 缺失文件不应导致崩溃。
- 列表仍可继续操作其他记录。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-015 1000 条数据搜索性能

前置条件：准备 1000 条测试记录，或使用自动测试生成等价数据。

步骤：

1. 打开含 1000 条记录的 library。
2. 搜索一个唯一关键词。
3. 搜索一个常见关键词。
4. 切换 tag、folder、model、favorite 组合筛选。
5. 快速清空搜索并切换列表。

预期结果：

- 搜索响应没有明显卡顿。
- 组合筛选结果正确。
- UI 不冻结。
- 输入搜索词时不丢字符。
- 自动 Core smoke 已覆盖 1000 条筛选 `< 500ms`。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-016 滚动和大库浏览性能

前置条件：library 至少 1000 条记录，包含图片和文本混合资产。

步骤：

1. 在列表中连续滚动到顶部、底部、中间。
2. 快速选择不同记录。
3. 观察详情区切换。
4. 观察缩略图加载。
5. 持续操作 5 分钟。

预期结果：

- 滚动流畅，无明显跳动。
- 选择记录不会错位。
- 详情区显示对应记录。
- 缩略图延迟加载可接受。
- 内存不应持续无上限增长。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-017 CLI 基础验收

前置条件：使用临时 library。

步骤：

1. 执行 `create-folder`。
2. 执行 `create-prompt`。
3. 执行 `list --query`。
4. 执行 `update-prompt`。
5. 执行 `favorite --on`。
6. 执行 `delete`、`list --trash`、`restore`、`get`。

预期结果：

- 成功命令输出合法 JSON。
- 数据写入指定 `--library`。
- CLI 创建的数据 App 可见。
- App 修改的数据 CLI 可读。
- 删除和恢复状态一致。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-018 CLI 错误处理

前置条件：使用临时 library。

步骤：

1. 缺少必填参数执行 create。
2. 使用不存在的导入文件路径。
3. 使用不存在的 item id。
4. 使用不存在的 folder id 移动记录。

预期结果：

- 命令返回非 0。
- 错误信息清楚。
- 不写入半成品数据。
- 不污染默认用户 library。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-019 MCP 工具验收

前置条件：启动 `PromptStudioMCP`，使用测试 library。

步骤：

1. 调用 `initialize`。
2. 调用 `tools/list`。
3. 调用 `create_prompt`。
4. 调用 `list_items`。
5. 调用 `get_item`。
6. 调用 `update_prompt`。
7. 调用 `import_files`。
8. 调用 `trash_item` 和 `restore_item`。
9. 传入缺失参数触发错误。

预期结果：

- `initialize` 返回 server info。
- `tools/list` 包含核心工具。
- 成功调用返回 JSON text。
- 写入结果 App / CLI / repository 一致。
- 缺失参数返回 JSON-RPC error。
- 不访问非指定 library。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-020 隐私和本地数据边界

前置条件：准备一条包含敏感文本的测试 Prompt。

步骤：

1. 创建敏感 Prompt。
2. 执行搜索、导出、复制、删除。
3. 查看命令行输出和错误日志。
4. 断网后重复核心本地操作。
5. 检查 App 是否仍可打开、搜索、复制、基础导出。

预期结果：

- App 默认不上传 prompt、文件、路径或 API key。
- CLI / MCP 只读写指定 library。
- 错误日志不泄露完整敏感 prompt。
- 断网不影响本地库基础功能。
- 只有用户明确导出或复制时，敏感内容才离开 App 内部视图。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-021 授权和功能门控

前置条件：存在未激活状态和 Pro 激活状态可测试。

步骤：

1. 未激活状态打开 App。
2. 尝试基础查看、基础搜索、复制、基础导出。
3. 尝试新建、编辑、导入、高级导出、集合管理。
4. 激活 Pro。
5. 重复上述受限功能。
6. 退出重开后检查授权状态。

预期结果：

- 未激活状态下基础能力可用。
- Pro 功能被明确提示限制。
- 激活后 Pro 功能可用。
- 授权提示不阻塞基础读取。
- 重启后授权状态保持正确。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

---

## TC-022 发布前回归检查

前置条件：准备 release candidate。

步骤：

1. 跑自动门禁。
2. 完整执行 TC-001 到 TC-021。
3. 执行 Release build。
4. 检查 App 图标、Info.plist、版本号。
5. 执行本地签名验证：
   ```sh
   codesign --verify --deep --strict --verbose=2 .build/release/PromptStudio.app
   codesign -dv --verbose=4 .build/release/PromptStudio.app 2>&1
   ```
6. 检查 sandbox、notarization 可用性。
7. 使用 `open .build/release/PromptStudio.app --args --library "$LIB"` 在干净测试 library 上首次启动。
8. 在已有旧 library 上启动，检查迁移。

预期结果：

- 自动测试通过。
- 手动核心用例无阻塞失败。
- Release build 成功。
- 版本号正确。
- 本地 `codesign --verify --deep --strict` 必须通过。
- notarization 如有 Apple 凭证则通过；无凭证则标记为环境跳过，不假失败。
- 新库和旧库都能正常打开。

结果：通过 / 失败 / 阻塞 / 跳过

备注：

## 缺陷记录模板

```text
缺陷编号：
关联用例：
严重级别：Critical / High / Medium / Low
类型：UI_REGRESSION / FUNCTIONAL_BUG / CRASH / PERFORMANCE / PERMISSION / ENVIRONMENT / UNKNOWN
复现步骤：
实际结果：
预期结果：
截图/日志：
是否可稳定复现：
影响范围：
建议处理：
```

## 最终 QA 结论模板

```text
测试日期：
测试版本：
测试人：
测试环境：
Library 状态：空库 / 种子库 / 100 条 / 1000 条 / 旧库迁移

自动测试：
- swift build：通过 / 失败
- swift test：通过 / 失败
- PromptStudioCoreUnitTests：通过 / 失败
- PromptStudioSmokeTests：通过 / 失败

手动测试：
- 通过用例数：
- 失败用例数：
- 阻塞用例数：
- 跳过用例数：

上线结论：
- READY_TO_SHIP：核心用例和发布门禁通过
- NEEDS_FIXES：存在必须修复问题
- BLOCKED：环境或构建问题导致无法判断

主要风险：
遗留问题：
```
