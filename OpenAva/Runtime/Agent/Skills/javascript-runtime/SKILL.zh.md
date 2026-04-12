---
name: javascript-runtime
description: 在内置的 JavaScript 运行时中执行代码，支持内联代码、单文件脚本、async、持久会话和 Tool 调用。
when_to_use: 当这个任务更适合通过实际执行 JavaScript 来完成，并希望结果来自代码执行而不只是自然语言推理时，可使用此技能。
user-invocable: false
allowed-tools:
  - javascript_execute
metadata:
  display_name: JavaScript Runtime
  emoji: ⚙️
---

# JavaScript 运行时

当一个任务更适合通过 OpenAva 内置 JavaScript 运行时执行短小、确定性的脚本来完成，而不是完全依赖自然语言推理时，使用这个技能。你既可以直接传入内联 `code`，也可以通过 `script_path` 执行工作区中的单文件脚本。若后续步骤需要延续变量、函数或中间状态，可主动复用同一个 `session_id`。

典型适用场景：

- JSON 重组、过滤、分组、排序、聚合
- 字符串解析、规范化、模板生成、报告整理
- 具有多个中间步骤的小型确定性计算
- 在 JavaScript 中调用一个或多个只读 Tool 并合并结果
- 执行工作区里已经存在的小型可复用脚本文件，而不必额外启用 sub-agent
- 需要通过代码而不是猜测来生成稳定的结构化输出

避免在以下场景使用：

- 直接调用某个 Tool 就能干净解决问题
- 转换逻辑非常简单，用普通推理更直接
- 任务需要浏览器 DOM API 或网页上下文
- 任务需要复杂、长期、开放式的多轮状态管理，更适合专门的 sub-agent 或其他机制

## 运行时模型

`javascript_execute` Tool 基于 Apple 系统自带 `JavaScriptCore` 执行代码。

重要规则：

- `code` 与 `script_path` 必须二选一
- `script_path` 必须指向当前工作区内的单个文件
- 你的 `code` 会作为 **async 函数体** 执行
- 用 `return` 返回最终结果
- 可以直接使用 `await`
- 输入数据通过 `openava.input` 提供
- 可通过 `session_id` 复用同一个持久 JS 上下文
- 同一 `session_id` 下可通过 `openava.session` 共享变量与状态
- 可通过 `await openava.tools.call(functionName, args)` 调用 Tool
- `console.log/info/warn/error` 会被捕获并包含在工具返回中
- 单文件脚本执行并不等于 Node.js 模块运行时；不要假设存在 `require`、`import`、`process` 或 Node 标准库

## 推荐工作流

1. 先判断 JavaScript 是否确实能减少歧义或重复推理。
2. 先判断是直接传内联 `code` 更清晰，还是复用工作区里的 `script_path` 更合适；只有脚本本来就应保存在工作区时才优先用 `script_path`。
3. 如果任务数据较复杂，先整理一个紧凑的 `input` 对象；只有确实需要延续状态时再提供 `session_id`。
4. 编写最小且清晰的脚本，确保结果可确定复现。
5. 如果需要外部数据，在 JavaScript 内调用 Tool 并在那里合并结果。
6. 优先返回结构化结果；如需要自然语言总结，再在执行后整理。

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

### 单文件脚本示例

```json
{
  "script_path": "scripts/summarize.js",
  "input": {
    "path": "notes/today.txt"
  },
  "session_id": "js-summary"
}
```

当逻辑已经以单个脚本文件形式保存在工作区中，并且希望继续复用同一套 runtime / session 行为时，优先使用这种方式。

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
