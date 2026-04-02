---
name: javascript-runtime
description: 当任务需要确定性的解析、转换、校验、数值计算，或需要把一个或多个只读 Tool 的结果做紧凑编排时，使用内置 JavaScript 运行时技能。
when_to_use: 当任务要求解析、重组、规范化、过滤、排序、分组、聚合、对比、校验或计算结构化数据，或需要把多个 Tool 输出稳定合并成 JSON 风格结果时，优先考虑此技能。
user-invocable: false
allowed-tools:
  - javascript_execute
metadata:
  display_name: JavaScript Runtime
  emoji: ⚙️
---

# JavaScript 运行时

当一个任务更适合通过 OpenAva 内置 JavaScript 运行时执行短小、确定性的脚本来完成，而不是完全依赖自然语言推理时，使用这个技能。若后续步骤需要延续变量、函数或中间状态，可主动复用同一个 `session_id`。

典型适用场景：

- JSON 重组、过滤、分组、排序、聚合
- 字符串解析、规范化、模板生成、报告整理
- 具有多个中间步骤的小型确定性计算
- 在 JavaScript 中调用一个或多个只读 Tool 并合并结果
- 需要通过代码而不是猜测来生成稳定的结构化输出

避免在以下场景使用：

- 直接调用某个 Tool 就能干净解决问题
- 转换逻辑非常简单，用普通推理更直接
- 任务需要浏览器 DOM API 或网页上下文
- 任务需要复杂、长期、开放式的多轮状态管理，更适合专门的 sub-agent 或其他机制

## 运行时模型

`javascript_execute` Tool 基于 Apple 系统自带 `JavaScriptCore` 执行代码。

重要规则：

- 你的 `code` 会作为 **async 函数体** 执行
- 用 `return` 返回最终结果
- 可以直接使用 `await`
- 输入数据通过 `openava.input` 提供
- 可通过 `session_id` 复用同一个持久 JS 上下文
- 同一 `session_id` 下可通过 `openava.session` 共享变量与状态
- 可通过 `await openava.tools.call(functionName, args)` 调用 Tool
- `console.log/info/warn/error` 会被捕获并包含在工具返回中

## 推荐工作流

1. 先判断 JavaScript 是否确实能减少歧义或重复推理。
2. 如果任务数据较复杂，先整理一个紧凑的 `input` 对象；只有确实需要延续状态时再提供 `session_id`。
3. 编写最小且清晰的脚本，确保结果可确定复现。
4. 如果需要外部数据，在 JavaScript 内调用 Tool 并在那里合并结果。
5. 优先返回结构化结果；如需要自然语言总结，再在执行后整理。

## 在 JavaScript 中调用 Tool

运行时内可这样调用：

```js
const result = await openava.tools.call("fs_read", { path: "/absolute/path" });
if (!result.ok) {
  throw new Error(result.text || "Tool call failed");
}
return result;
```

说明：

- `result.text` 是原始文本 payload
- `result.payload` 会在 payload 是合法 JSON 时尽量解析为 JSON 值，否则可能仍是字符串
- `openava.session` 适合放置需要跨多次调用延续的缓存、中间结果或辅助函数
- 除非确有必要，否则让 Tool 编排保持简单、顺序化

### 持久 session 示例

首次调用：

```js
openava.session.counter = (openava.session.counter ?? 0) + 1;
return { counter: openava.session.counter };
```

后续调用只要继续传入同一个 `session_id`，`openava.session.counter` 就会保留。

## 输出约束

优先返回可 JSON 序列化的值，例如：

- object
- array
- string
- number
- boolean
- null

不要依赖：

- function 作为输出
- class 实例
- 循环引用结构
- DOM / 浏览器全局对象

## 推荐模式

### 确定性转换

```js
const rows = openava.input.rows ?? [];
return rows
  .filter(row => row.active)
  .map(row => ({ id: row.id, total: row.price * row.qty }))
  .sort((a, b) => b.total - a.total);
```

### Tool 辅助计算

```js
const file = await openava.tools.call("fs_read", { path: openava.input.path });
if (!file.ok) {
  throw new Error(file.text || "Failed to read file");
}

const text = typeof file.payload === "string" ? file.payload : (file.text || "");
const lines = text.split("\n").filter(Boolean);
return {
  lineCount: lines.length,
  firstLine: lines[0] ?? null,
};
```

## 决策规则

只有在代码执行能明显提升正确性、可重复性或表达紧凑度时，才使用这个技能。

如果 JavaScript 不是明显更优的执行媒介，就不要调用这个技能。
