# 图片 Prompt 对称正文边距设计

## 目标

图片右侧 Prompt 的正文在视觉上保持左右对称，不再因为滚动条出现而改变右侧正文边距或换行宽度。

## 最终布局规范

- 左边界到正文：`24pt`
- 正文到右边界：`24pt`
- 滚动条宽度：沿用 `TransparentOverlayScroller.knobWidth`，当前为 `6pt`
- 滚动条到右边界：`0pt`
- 滚动条作为覆盖层显示在右侧 `24pt` 空白区域内，不参与正文宽度计算
- 有滚动条与无滚动条时，正文使用完全相同的可用宽度和换行位置

因此，滚动条显示时，正文末端到滚动条内侧的可见间距为 `18pt`；该数值是 `24pt` 正文右边距扣除 `6pt` 覆盖滚动条后的结果，不单独维护。

## 组件与数据流

`SidePanelPromptTextBox` 继续作为图片 Prompt 的唯一共享入口，覆盖：

- 主界面图片右侧信息栏
- 图片沉浸预览右侧信息栏
- 新建/编辑 Prompt 的图片预览区域

`SidePanelPromptBoxLayout` 将正文右边距与滚动条宽度解耦：

- `textLeadingPadding = 24`
- `textTrailingPadding = 24`
- `scrollerRightInset = 0`
- `scrollContentRightInset = 0`

静态文本和可滚动文本必须读取同一组正文边距。滚动条继续使用 overlay 样式，显示或隐藏均不得改变文本容器宽度。

## 保持不变

- Prompt 字号、行距、上下边距、背景、圆角和描边
- 点击复制、选区复制、Hover 提示及复制反馈
- 自动高度、最大高度和底部提示保护区
- 图片信息栏宽度同步逻辑
- MD 文档预览布局

## 验收标准

1. 短 Prompt 无滚动条时，正文左右边距均为 `24pt`。
2. 长 Prompt 显示滚动条时，正文左右边距仍均为 `24pt`，换行位置不因滚动条显示而变化。
3. 滚动条宽 `6pt` 且贴右边界，位于右侧 `24pt` 空白区域内。
4. 主界面图片信息栏、图片沉浸预览和创建预览显示一致。
5. Prompt 复制、选区复制、Hover、滚动及窗口缩放行为保持正常。

## 回归检查

- 源代码检查禁止重新使用“正文右边距 = 滚动条宽度”的耦合公式。
- 检查三个图片 Prompt 入口继续使用 `SidePanelPromptTextBox`。
- 运行 Prompt 间距回归、发布 UI 回归、Swift Debug 构建、核心测试和 Smoke Test。
