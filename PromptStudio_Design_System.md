---
version: 1.0
name: PromptStudio 设计系统
description: 深色原生 macOS 素材与 Prompt 管理工具设计系统，强调低干扰信息密度、沉浸预览、文档级文本编辑和 Codex Desktop 风格的克制深色界面。
---

## 概述

PromptStudio 的视觉方向是本地原生 macOS 深色生产力工具，而不是营销页或内容消费型产品。整体界面以近黑画布、深灰面板、低饱和描边和少量白色主操作构成，重点服务素材扫描、Prompt 阅读、文档编辑和批量管理。

设计应保持安静、稳定和信息优先。中间瀑布流是主工作区，左侧文件夹栏负责空间定位，右侧 Inspector 负责选中项的结构化信息与快捷动作，全窗口 overlay 用于高沉浸预览和强编辑场景。

核心原则：

- 主界面不使用大面积彩色装饰。
- 信息卡片尽量减少遮挡，未选中素材只显示内容本身。
- 操作按钮优先使用图标，文字按钮只用于明确提交类动作。
- 文档、Prompt、图片/视频信息必须分层显示，不把所有字段平铺。
- 所有交互反馈以描边、轻微背景变化、透明度和小幅缩放完成。

## 颜色

### 品牌与强调色

| Token | 色值 | 用途 |
|---|---:|---|
| `primaryAction` | `#FFFFFF` | 主按钮、选中描边、强可点击状态 |
| `primaryActionText` | `#0A0A0A` | 白色主按钮上的文字 |
| `blue` | `#0285FF` | 系统级蓝色强调，少量使用 |
| `orange` | `#FF7A17` | 警示或次级强调 |
| `dusk` | `#7C3AED` | 低频品牌辅助色 |
| `twilight` | `#C4B5FD` | 紫色弱辅助色 |

### 表面色

| Token | 色值 | 用途 |
|---|---:|---|
| `appBackground` | `#0A0A0A` | App 主背景、沉浸预览背景 |
| `previewBackground` | `#181818` | 预览/内容承载区背景 |
| `sidebar` | `#333333` | 侧边栏深灰基底 |
| `panel` | `#141414` | Inspector、右侧栏、底层面板 |
| `panelRaised` | `#1E1E1E` | hover/浮起面板 |
| `control` | `#1F1F1F` | chip、按钮、输入控件背景 |
| `controlPressed` | `#242424` | 按下状态 |
| `selection` | `#1F1F1F` | 选中态和 hover 底色 |
| `hairline` | `#212327` | 1px 分割线和低调描边 |

### 文字色

| Token | 色值 | 用途 |
|---|---:|---|
| `text` | `#FFFFFF` | 主标题、重要文本、图标 |
| `secondaryText` | `#DADBDF` | 正文、说明、Prompt 内容 |
| `tertiaryText` | `#FFFFFF` 60% | 占位、弱信息、空状态 |
| `sectionTitleText` | `#FFFFFF` 60% | 分组标题 |
| `mutedText` | `#7D8187` | 行号、弱元信息 |

### 文档语义色

文档编辑器和文本类封面使用低彩度语义高亮。普通正文不使用纯白，避免长文本刺眼。

| 语义 | 色值 | 用途 |
|---|---:|---|
| 灰色 | `#BDBEC0` | 文档正文、行号、分割线 |
| 蓝色 | `#41CBE0` | Markdown 标题 |
| 绿色 | `#37DD61` | 行内代码、引用 marker |
| 橙色 | `#FF9F0A` | 列表 marker |
| 红色 | `#FF5F57` | 负面约束整行 |
| 白色 | `#EEEEEE` | Markdown 加粗强调 |

### 渐变 / 特殊效果

- 不使用装饰性渐变背景、光斑、彩色 blob。
- 瀑布流选中卡片底部允许使用半透明黑色蒙版，目的是降低遮挡而不是制造装饰。
- 左侧侧栏使用 macOS `NSVisualEffectView.sidebar` 毛玻璃材质，透明度应保持克制。

## 排版

### 字体家族

| 场景 | 字体 |
|---|---|
| App UI | `PingFang SC` |
| 文档编辑器正文 | `PingFangSC-Regular` |
| 行号 | macOS monospaced digit system font |
| 图标 | SF Symbols 或 Lucide 图标 |

### 层级表

| Token | 字号 | 字重 | 行高/间距 | 字距 | 用途 |
|---|---:|---|---|---:|---|
| `overlayTitle` | 22 | medium | 默认 | 0 | 新建 Prompt 全窗口标题 |
| `inspectorTitle` | 14-15 | regular/semibold | 默认 | 0 | 右侧栏标题、素材标题 |
| `body` | 14 | regular | 默认 | 0 | 通用正文、表单文本 |
| `promptBody` | 13 | regular | lineSpacing 4 | 0 | 右侧 Prompt 框、预览 Prompt |
| `documentBodyFull` | 14 | regular | lineSpacing 4 | 0 | 全屏文档预览/编辑 |
| `documentBodyInspector` | 13 | regular | lineSpacing 4 | 0 | 右侧文档预览 |
| `lineNumber` | 12 | regular | 跟随正文 | 0 | 文档编辑器行号 |
| `button` | 12 | medium | 默认 | 0 | 胶囊按钮、tab |
| `caption` | 12 | regular | 默认 | 0-1.2 | 分组标题、辅助说明 |
| `chip` | 11 | regular/medium | 默认 | 0 | 标签、格式、版本 chip |

### 原则

- 不使用负字距。
- 不把视口宽度映射到字号。
- 按钮文字 12px，正文常规 13-14px，右侧栏更紧凑。
- 标题不滥用大字号，生产力界面保持密度。
- 文档编辑器所有语义高亮当前都使用 regular，不用粗体制造大面积视觉噪音。

## 布局与间距

### 间距系统

界面以 4px/8px 为基准，但不强制 token 化。常用间距：

| Token | 值 | 用途 |
|---|---:|---|
| `xxs` | 4 | icon 与文本、紧凑元素内部 |
| `xs` | 6-8 | chip 间距、列表小间距 |
| `sm` | 10-12 | 按钮内间距、紧凑 stack |
| `md` | 14-18 | Inspector 内容块间距 |
| `lg` | 20-24 | 面板水平 padding、模块间距 |
| `xl` | 34-42 | 预览主图边距、overlay 内容边距 |
| `contentTopPadding` | 40 | Inspector/主内容顶部对齐 |
| `composerOuter` | 40-64 | 新建 Prompt 页面大边距 |

### 网格/容器

- 主界面为三栏：左侧毛玻璃文件夹栏、中间瀑布流、右侧 Inspector。
- 中间瀑布流使用多列 masonry，卡片根据素材比例计算高度。
- 右侧 Inspector 固定窄栏，内容应优先纵向扫描。
- 全窗口预览使用左主内容 + 右信息栏两栏布局。
- 新建 Prompt Composer 使用左输入区 + 中上传区 + 右实时预览栏，Prompt 输入区必须是第一视觉层级。

### 留白习惯

- 右侧 Inspector 内容左右 padding 20-24px。
- 卡片内容只在选中态显示底部信息层，未选中不显示标题、badge、按钮。
- Prompt 信息框内边距 14px。
- 文档编辑器文本容器 inset：水平 14px，垂直 24px。

## 圆角与形状

### 圆角等级

| Token | 值 | 用途 |
|---|---:|---|
| `xs` | 3 | OpenPromptStudio 兼容小按钮 |
| `sm` | 8 | 面板、输入框、缩略图、普通卡片 |
| `md` | 12 | 瀑布流素材卡片 |
| `selection` | 15 | 选中卡片外描边 |
| `pill` | 999 | chip、胶囊按钮 |
| `circle` | 50% | icon button |

### 特殊形状

- 主按钮使用胶囊形。
- chip 使用胶囊形。
- icon button 使用 28px 圆形。
- 瀑布流卡片使用 12px 圆角，选中描边略大一圈。

## 阴影与深度

PromptStudio 主要通过层级色和描边表达深度，不依赖明显投影。

| Level | 表达方式 | 用途 |
|---|---|---|
| 0 | `#0A0A0A` 背景 | 主画布 |
| 1 | `#141414` 面板 + `#212327` 描边 | Inspector、文档编辑器 |
| 2 | `#1F1F1F` 控件背景 | chip、按钮、输入区 |
| 3 | `#1E1E1E` hover/raised | hover 控件、浮起区域 |

约束：

- 不使用强投影制造卡片堆叠感。
- 可以在 toast、overlay、拖拽预览中使用轻量阴影，但不要让阴影成为主视觉。
- 预览页以全黑背景和右栏分割线建立空间关系。

## 组件样式

### 按钮

#### 主按钮

- 背景：`#FFFFFF`
- 文字：`#0A0A0A`
- 字号：12px medium
- 高度：34px
- 左右 padding：16px
- 形状：胶囊
- hover：背景变为 `secondaryText`
- pressed：opacity 0.75

#### 次级按钮

- 背景：`#1F1F1F`
- 文字：`#FFFFFF`
- 描边：`#212327`
- hover：背景 `selection`，描边白色 42% opacity
- pressed：opacity 0.75

#### Icon Button

- 尺寸：28 x 28
- 背景：`#1F1F1F`
- 图标：14px，白色
- 描边：`#212327`
- hover：描边白色 42% opacity，scale 1.04
- pressed：opacity 0.72

### 卡片

#### 瀑布流素材卡片

- 未选中：只显示素材本体，不显示标题、badge、按钮、渐变。
- 选中：1.5px 白色半透明描边。
- 选中底部：半透明黑色蒙版，显示标题一行和快捷按钮。
- 卡片圆角：12px。
- 文档卡片直接渲染文本第一屏，不依赖旧缩略图缓存。

#### 文档卡片

- 背景：`#141414`
- 描边：`#363A3F`
- 文本：正文灰 `#BDBEC0`
- 标题：蓝 `#41CBE0`
- 不显示行号，保留轻量语义高亮。

### 导航栏 / 侧边栏

- 侧边栏使用 macOS sidebar 毛玻璃材质。
- 行高保持紧凑，icon + 文本 + count 右对齐。
- 选中行使用深色半透明背景。
- 文件夹树支持多级缩进，图标和文本应保持低调白色，不使用彩色文件夹。

### 输入框

- 背景：`#1F1F1F` 或 Composer 中 `#2D2D2D` 级深灰。
- 描边：白色低透明或 `#212327`。
- 圆角：8px。
- 字号：13-14px。
- placeholder：白色 45%-60% opacity。
- 不使用亮色 focus ring；focus 以轻微描边变化表达。

### 标签 / Badge / Chip

- 背景：`#1F1F1F`
- 描边：`#212327`
- 文字：`#DADBDF`
- 字号：11px
- 高度：26px
- 左右 padding：10px
- 形状：胶囊
- 文档语义 chip 当前保持低调灰色，不使用大面积彩色底。

### Prompt 信息框

- 背景：`#2D2D2D`
- 描边：1px `#3E3E3E`
- 圆角：8px
- 文字：13px regular
- 行距：4px
- 短 Prompt：容器随内容自适应。
- 长 Prompt：容器拉到可用底部，在框内滚动。
- 无 Prompt：不显示大空框，仅显示小字“暂无提示词”。

### Markdown / 文本文档编辑器

- 背景：`#141414`
- 描边：`#363A3F`
- 圆角：8px
- 行号栏宽：44px
- 行号：12px，monospaced digit，灰色
- 全屏正文：14px
- 右侧 Inspector 正文：13px
- 文本 inset：水平 14px，垂直 24px
- 高亮规则：
  - 标题整行：蓝色 `#41CBE0`
  - 引用 marker `>`：绿色 `#37DD61`
  - 列表 marker：橙色 `#FF9F0A`
  - 行内代码：绿色 `#37DD61`
  - 负面约束整行：红色 `#FF5F57`
  - `**加粗**`：白色 `#EEEEEE`
  - 普通正文：灰色 `#BDBEC0`

### 全窗口预览

- 背景：`#0A0A0A`
- 左侧为图片/视频/文档主内容。
- 右侧栏宽约 360px，背景 `#141414` 96% opacity。
- 关闭按钮位于右上角，小圆形 icon。
- 图片缩放控件在左下角；主界面的缩略图比例控件不使用外层背景。

### 新建 Prompt Composer

- 全窗口 overlay，不开独立窗口。
- 左侧是标题、类型、模型、Prompt 输入。
- 中间是提示词预览图和参考图上传。
- 右侧复用 Inspector 风格的实时预览。
- 标题 14px，按钮 12px，正文 13px；不得出现过大的表单视觉。
- 未输入内容时，右侧预览不展示空模块；输入什么展示什么。

### Toast

- 出现在底部。
- 深色背景，白色文本。
- 动效使用 move from bottom + opacity + 0.98 scale；reduce motion 时只使用 opacity。

## 注意事项（Do's and Don'ts）

### 应做

- 应优先使用 `StudioColor`、`StudioFont`、`StudioMotion`。
- 应保持 UI 深色、低干扰、高信息密度。
- 应让图片/视频/文档的预览与编辑使用一致的信息层级。
- 应让主操作明显但不彩色化。
- 应用 Lucide 或 SF Symbols 图标承载常见动作。
- 应保持 hover/pressed 状态轻微、快速、可预测。
- 应让长文本在自己的容器内滚动，而不是撑爆右栏。

### 不应做

- 不应使用装饰性渐变、光斑、彩色背景球。
- 不应让未选中卡片显示标题、badge 或按钮。
- 不应把标签作为核心功能过度突出。
- 不应把所有信息塞进右侧栏顶部。
- 不应使用大面积红、绿、蓝语义色。
- 不应让圆角超过当前等级体系，避免卡通化。
- 不应引入 Web 风格 landing page 或营销式 hero。
- 不应在原生 macOS 工具里使用过重阴影和高饱和彩色块。

## 附注

- PromptStudio 的风格接近 Codex Desktop：黑色底、低饱和边界、文本优先、操作克制。
- Midjourney 的右侧信息栏可作为 Prompt 展示密度参考，但 PromptStudio 需要保留本地文件、版本、导出、文档编辑等生产力功能。
- 文本类素材应被当作一等素材展示，卡片可直接渲染文本第一屏，右侧和全屏预览复用文档编辑器。
- Word 文档属于可读文本类，但 PDF/PPT/Excel 不应默认进入 Markdown 编辑体系。
