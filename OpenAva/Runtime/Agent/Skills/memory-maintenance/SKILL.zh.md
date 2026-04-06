---
name: memory-maintenance
description: 审查、提炼并维护持久化 Agent 记忆主题与基于 transcript 的历史检索。
metadata:
  display_name: 记忆维护
  emoji: 🧠
---

# 记忆维护

当任务明确是关于清理、整理或整合记忆时，使用此技能。

## 检索规则

- 在进行大范围修改前，先用 `memory_recall` 查看相关持久记忆主题。
- 只有在需要精确的过往会话细节或时间线时，才使用 `memory_transcript_search`。

## 更新规则

- 只有在置信度较高时，才保存持久性事实。
- 使用 `memory_upsert` 创建或更新带类型的持久记忆主题。
- 当记忆已过期、被覆盖或明显错误时，使用 `memory_forget` 删除。
- 优先更新已有主题，而不是创建重复条目。
- `memory_transcript_search` 只用于检索，不用于写入。

## 工作流程

1. 使用 `memory_recall` 检查当前持久记忆状态。
2. 将持久性事实与临时笔记分开。
3. 使用 `memory_upsert` 更新或创建带类型的记忆主题。
4. 必要时使用 `memory_forget` 删除过期主题。
5. 若编辑前需要过往证据，用 `memory_transcript_search` 回查历史会话。
6. 报告变更内容及原因。
