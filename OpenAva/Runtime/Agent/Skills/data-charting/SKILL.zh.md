---
name: data-charting
description: 将结构化数据转化为清晰的图表 Markdown 块，供支持图表渲染的消息渲染器使用。
metadata:
  display_name: 数据图表
  emoji: 📊
---

# 数据图表

当用户需要以下操作时，使用此技能：

- 可视化指标、趋势、分布或比例。
- 将表格/JSON 数据转化为图表。
- 跨时间或类别比较多个数据系列。
- 在图表中显示阈值、范围或基准规则。

此技能使用围栏代码块为**应用内消息渲染器**（聊天消息列表 UI）输出图表 Markdown：

````markdown
```chart
{ ...json... }
```
````

## 核心规则

- 始终在 ` ```chart ` 块内输出有效的 JSON。
- 将数字字段保持为数字，而非字符串。
- 每个图表聚焦于一个分析问题。
- 优先使用简洁的标题和有意义的系列名称。
- 若数据缺失或有歧义，在图表前简要说明假设。

## 运行时目标

- 目标渲染器：任何支持 ` ```chart ` 围栏块的聊天/消息渲染器。
- 预期格式：带有语言标签 `chart` 的围栏代码块和一个 JSON 对象。
- 若不确定，仍然输出确切的 ` ```chart + JSON ` 结构。

## 支持的图表类型

将 `kind` 设置为以下之一：

- `line`（折线图）
- `area`（面积图）
- `bar`（柱状图）
- `point`（散点图）
- `rule`（参考线）
- `rectangle`（矩形区域）
- `pie`（饼图）

## JSON 模式

### 1) `line` / `area` / `bar` / `point`

```json
{
  "kind": "line",
  "title": "Weekly Visits",
  "height": 240,
  "line": {
    "x": ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "series": [
      { "name": "PV", "y": [120, 180, 160, 220, 260] },
      { "name": "UV", "y": [80, 110, 105, 130, 150] }
    ]
  }
}
```

注意：

- `area` 时，将 `line` 替换为 `area`。
- `bar` 时，将 `line` 替换为 `bar`。
- `point` 时，将 `line` 替换为 `point`。
- 每个 `series[i].y` 的数量必须等于 `x` 的数量。

### 2) `pie`

```json
{
  "kind": "pie",
  "title": "Traffic Source Share",
  "height": 240,
  "pie": {
    "items": [
      { "name": "Organic", "value": 45 },
      { "name": "Ads", "value": 35 },
      { "name": "Referral", "value": 20 }
    ]
  }
}
```

### 3) `rule`

```json
{
  "kind": "rule",
  "title": "Alert Thresholds",
  "height": 220,
  "rule": {
    "yValues": [100, 180, 250]
  }
}
```

### 4) `rectangle`

```json
{
  "kind": "rectangle",
  "title": "Value Ranges by Period",
  "height": 260,
  "rectangle": {
    "items": [
      {
        "label": "Stable Zone",
        "xStart": "Q1",
        "xEnd": "Q2",
        "yStart": 80,
        "yEnd": 140
      },
      {
        "label": "Target Zone",
        "xStart": "Q3",
        "xEnd": "Q4",
        "yStart": 120,
        "yEnd": 200
      }
    ]
  }
}
```

## 图表选择指南

- 使用 `line` 进行时间趋势对比。
- 使用 `area` 表现随时间累积/量感。
- 使用 `bar` 进行类别对比。
- 使用 `point` 展示稀疏观测值或类散点图快照。
- 使用 `pie` 展示有限类别的构成比例。
- 使用 `rule` 叠加阈值/基准线。
- 使用 `rectangle` 突出显示区间/范围。

## 工作流程

1. 理解问题（趋势、对比、占比、阈值、范围）。
2. 将来源数据规范化为 `x` 加数值。
3. 选择最合适的 `kind`。
4. 每个图表生成一个 ` ```chart ` 块。
5. 可选：在图表后添加 1 至 2 句洞察。

## 质量标准

- 不编造数据点。
- 不输出格式错误的 JSON。
- 图表标题简短且具体。
- 类别标签易于阅读。
- 饼图类别不超过 8 个，以保证可读性。
