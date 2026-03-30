---
name: github-trending
description: 聚合 GitHub Trending 与相关信号，面向热门项目追踪、语言/领域趋势观察、竞品扫描与技术选型，输出含证据和风险的可执行结论。
metadata:
  display_name: GitHub 热门趋势
  emoji: 📈
---

# GitHub Trending 探索

## 核心能力

- 抓取并整理 GitHub Trending 的热门仓库与开发者信号。
- 对项目做结构化比较，输出可用于学习、对标与选型的结论。

## 数据源优先级

1. **Primary: GitHub Trending**
   - `https://github.com/trending`
   - `https://github.com/trending/{language}`
   - `https://github.com/trending?since=daily|weekly|monthly`
2. **Secondary: GitHub API**
   - 用于补充 stars、活跃度、创建时间等基础指标。
3. **Supplementary: 社区信号**
   - 仅作交叉验证，不作为单一结论依据。

## 执行流程

1. 明确范围：时间窗口、语言/领域、目标（追踪/竞品/选型）。
2. 抓取候选：先取 Trending，再用 API 补充可验证指标。
3. 结构化评估：按增长、健康度、落地性进行横向比较。
4. 输出结果：给出结论、证据、风险和建议动作。

## 评估框架（精简）

### 1) 增长信号

- Stars 规模与近期增速
- Forks/Contributors 变化

### 2) 健康度信号

- 最近提交频率
- Issue/PR 活跃度与响应情况
- 文档与 License 完整性

### 3) 落地性信号

- 解决问题是否清晰
- 上手成本与集成复杂度
- 竞品差异和替代成本

## 输出要求

- 先给结论，再给证据；避免堆砌指标。
- 不编造 Star 增长、提交频率或社区活跃度。
- 数据缺失明确标注 `unknown`。
- 含时效性的观察标注"以当前抓取时间为准"。
- 用户目标是选型/落地时，必须补充风险与替代方案。

## 默认输出模板

```markdown
# GitHub Trending 简报 - {date}

## 结论
{一句话结论：当前最值得关注的方向与原因}

## 热门项目 TOP 5
| 项目 | 语言 | 关键指标 | 入选原因 | 风险 |
|------|------|----------|----------|------|
| {name} | {lang} | {stars / delta} | {reason} | {risk_or_unknown} |

## 选型建议（可选）
- 推荐: {project}，因为 {why}
- 替代: {alternative}，适合 {scenario}
- 注意: {risk}
```
