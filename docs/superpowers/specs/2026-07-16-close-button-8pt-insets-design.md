# 页面级关闭按钮 8pt 边距设计

## 目标

将 PromptStudio 所有使用共享 `StudioCloseButton` 定位器的页面级右上角关闭按钮，统一调整为距内容区域顶部和右侧各 `8pt`，减少按钮与窗口边缘之间的空隙。

## 范围

- 图片与视频沉浸式预览。
- Markdown 沉浸式预览。
- 新建与编辑 Prompt 覆盖层。
- 设置页。

标签、参考图、附件和内容卡片上的删除小叉不使用此页面级定位器，不做修改。

## 设计

- 共享指标 `topInset` 从 `24pt` 改为 `8pt`。
- 共享指标 `trailingInset` 从 `24pt` 改为 `8pt`。
- 继续由 `studioTopTrailingCloseButton` 统一定位，避免各页面单独维护边距。
- 保持按钮与点击区域 `34×34pt`、`12pt semibold` 图标、圆形背景与描边、Hover 变亮与 `1.04` 缩放。
- Reduced Motion、Help、VoiceOver 标签和每个页面原有关闭逻辑保持不变。

## 验证

- 发布 UI 回归检查必须要求共享边距为 `8pt`，修改前失败、修改后通过。
- Swift Debug 构建、核心测试、Smoke Test、License 与签名策略检查通过。
- 手动打开媒体预览、Markdown 预览、Prompt 覆盖层和设置页，检查按钮位置和交互一致。
