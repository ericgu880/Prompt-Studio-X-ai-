# PromptStudio 网页图片采集与桌宠投喂

## 产品流程

- 右键图片：获取原图后，桌宠移动到鼠标附近，展示缩略图和采集方式；用户确认后保存。
- 右键普通元素：识别该元素顶层有效 CSS `background-image` 并执行同一确认流程。
- 拖拽图片：创建单一活动会话并预取资源；桌宠移动到图片旁，拖入嘴部时显示缩小副本，松手立即保存，拖出或取消则清理。
- 无法取得原图时，使用当前可见网页截图按元素可见区域裁剪 PNG，并标记“截图采集”。
- 桌宠隐藏时为图片交互临时出现，完成或取消后恢复隐藏。

## 浏览器扩展

- Manifest V3 新增 `contextMenus`、`scripting`，内容脚本启用 `all_frames`；不申请 `debugger`、Cookie、浏览历史或额外 `tabs` 权限。
- DOM 解析顺序：`currentSrc`、`srcset` 最高分辨率候选、Data URL / Blob / Canvas / 内联 SVG、CSS 顶层有效 `background-image`。
- 字节获取顺序：页面主世界读取、扩展后台跨域请求、已加载 Blob/Data 转换、`captureVisibleTab` 裁剪。
- 原图按 512KiB 原始数据分片传输，Base64 JSON 帧必须低于现有 1MiB Native Messaging 上限。
- `dragstart` 建立会话并预取；`dragend` 未完成时发送取消并清理。

## Native Host 与桌宠

- 协议消息：`imageBegin`、`imageChunk`、`imageEnd`、`imageCancel`、`imageDragPreview`、`imageDragCancel`。
- Host 只接收浏览器字节，不请求远程 URL；只向 App 传递随机 staging token，不接受浏览器本地路径。
- 暂存目录为 `~/Library/Application Support/PromptStudio/CaptureStaging`，目录权限 `0700`，文件权限 `0600`。
- 校验 SHA-256；单图最大 50MB；传输超时 120 秒；暂存文件 TTL 10 分钟。
- 右键复用 `asking → eating → success/error`；拖拽使用独立 `ImageDropPhase`。
- 同时只允许一个图片会话，第二个请求返回 `image-busy` 且 `retryable: true`。

## 公共类型与入库

- 新增 `WebImageCaptureCandidate`、`ImageDOMSourceKind`、`ImageAcquisitionMethod` 与 `createCapturedImage(_:stagedFileURL:)`。
- `CapturedSource` 增加可空字段：资源 URL、DOM 来源类型、获取方式、是否截图；旧 JSON 保持可解码，不新增 SQLite 列。
- App 校验暂存文件所有权、SHA-256、真实图片格式、50MB、最多 100MP，再复制到 `assets/images`。
- 复用 `captureID` 唯一索引，断线重试保持幂等。
- 标题优先级：alt → 原文件名 → 页面标题 →“网页图片”。
- 固定保存到“待整理”，标签为“网页采集 / 图片采集 / 待整理”；截图增加“截图采集”。
- 保留 GIF/WebP 等原始字节及动画；截图输出 PNG。
- 资源 URL 删除嵌入式账号密码和 fragment，保留 query；日志不记录完整 URL或图片内容。

## 验收

- 扩展覆盖 currentSrc/srcset、登录态、Referer、防盗链、Blob、Data URL、CSS、Canvas、内联 SVG、跨域 iframe、截图裁剪、多显示器坐标。
- 协议覆盖乱序、重复、截断、摘要错误、超限、断线、超时、伪造 token 和非法来源。
- Core 覆盖 100MP 边界、格式伪装、动画原文件、截图标签、旧 JSON 和 captureID 幂等。
- 交互覆盖右键确认/取消、拖入/拖出/松手、隐藏恢复、忙碌、减少动态效果和保存失败。
- Chrome、Edge、Arc 端到端连续 100 次采集，无丢失、无重复、无残留暂存文件。

## 约束

- 第一版仅 macOS；Safari 和 Windows 不包含。
- CSS 背景图仅支持右键采集，不强制改写网页拖拽。
- 截图兜底只保存当前可见区域并明确标记。
- 不绕过 DRM、付费墙或当前用户无权访问的内容。

