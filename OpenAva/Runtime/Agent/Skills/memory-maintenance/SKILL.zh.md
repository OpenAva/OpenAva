---
name: memory-maintenance
description: 审查、提炼并维护长期记忆和可搜索的历史记录。
metadata:
  display_name: 记忆维护
  emoji: 🧠
---

# 记忆维护

当任务明确是关于清理、整理或整合记忆时，使用此技能。

## 检索规则

- 在进行大范围修改前，先读取当前长期记忆。
- 对于历史事件，使用聚焦查询调用 `memory_history_search`。
- 当请求依赖原始日记时，读取近期的 `memory/YYYY-MM-DD.md` 文件。

## 更新规则

- 只有在置信度较高时，才将持久性事实保存到长期记忆中。
- 使用 `memory_write_long_term` 而非通用文件写入来处理 `MEMORY.md`。
- 使用 `memory_append_history` 而非通用文件写入来处理 `HISTORY.md`。
- 保持历史条目事实准确、简洁且以时间为导向。
- 不重复未变更的长期记忆内容。

## 工作流程

1. 检查当前记忆状态。
2. 将持久性事实与临时笔记分开。
3. 只将值得延续的信息更新到 `MEMORY.md`。
4. 当一个决策、里程碑或摘要需要保持可搜索时，向 `HISTORY.md` 追加事实性条目。
5. 报告变更内容及原因。
