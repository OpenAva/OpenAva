---
name: javascript-runtime
description: Execute JavaScript in the built-in JavaScript runtime, with support for inline code, single-file scripts, minimal CommonJS, async code, persistent sessions, and tool calls.
when_to_use: Use when the solution should be carried out by executing JavaScript, so the result comes from code execution rather than only natural-language reasoning.
user-invocable: false
allowed-tools:
  - javascript_execute
metadata:
  display_name: JavaScript Runtime
  emoji: ⚙️
---

# JavaScript Runtime

Use this skill when the task is better solved by executing short, deterministic JavaScript inside OpenAva's built-in JavaScript runtime instead of reasoning everything manually. You can either pass inline `code` directly or run a single workspace script through `script_path`, and both entry modes share the same minimal CommonJS shape with `require`, `module.exports`, `exports`, `__filename`, `__dirname`, and a minimal `process`. When later steps need to keep variables, helper functions, or intermediate state, reuse the same `session_id`.

Typical fits:

- JSON reshaping, filtering, grouping, sorting, aggregation
- String parsing, normalization, templating, and report generation
- Small deterministic calculations with multiple intermediate steps
- Calling one or more read-only tools from JavaScript and combining the results
- Running a small reusable workspace script file without introducing a separate sub-agent
- Producing stable structured output that should be derived from code, not guesswork

Avoid using this skill when:

- A direct tool call already solves the task cleanly
- The transformation is trivial enough to do in plain reasoning
- The task needs browser DOM APIs or a web page context
- The task requires complex, long-running, open-ended state management better handled by a dedicated sub-agent or another mechanism

## Runtime Model

The `javascript_execute` tool runs code inside Apple system `JavaScriptCore`.

Important runtime rules:

- Provide exactly one of `code` or `script_path`
- `script_path` must point to a single file inside the active workspace
- Your `code` is executed as the **body of an async function**
- Use `return` for the final result
- You may use `await`
- Input data is exposed as `openava.input`
- You may provide `session_id` to reuse the same persistent JavaScript context
- Shared cross-call state is available through `openava.session`
- Tool calls are available through `await openava.tools.call(functionName, args)`
- `console.log/info/warn/error` are captured and returned in the tool result
- `code` and `script_path` share the same **minimal CommonJS** surface: `require`, `module.exports`, `exports`, `__filename`, `__dirname`
- Both entry modes also expose a **minimal `process`** object with `argv`, `cwd()`, `env`, `platform`, and `versions`
- A built-in **`path`** module is available through `require("path")` or `require("node:path")`
- When using inline `code`, relative `require()` resolves from the active workspace root
- Do not assume ESM `import`, package resolution, built-in Node modules, timers, `Buffer`, `child_process`, or other Node standard libraries are available

## Preferred Workflow

1. Decide whether JavaScript meaningfully reduces ambiguity or repetitive reasoning.
2. Decide whether inline `code` or a reusable `script_path` is clearer; prefer `script_path` only when the script already belongs in the workspace.
3. Prepare a compact `input` object for the script when the task has non-trivial data; only provide `session_id` when state reuse is genuinely useful.
4. Write the smallest clear script that produces the final answer deterministically.
5. If external data is needed, call tools from inside JavaScript and combine their outputs there.
6. Return a structured result first; convert it into prose only after execution if needed.

## Calling Other Tools from JavaScript

Inside the runtime, call tools like this:

```js
const result = await openava.tools.call("fs_read", { path: "/absolute/path" });
if (!result.ok) {
  throw new Error(result.text || "Tool call failed");
}
return result;
```

Notes:

- `result.text` is the raw tool payload as text
- `result.payload` is a best-effort parsed JSON value when the payload is valid JSON; otherwise it may be a string
- `openava.session` is the right place for caches, intermediate state, and helper functions that should survive across calls in the same session
- Keep tool orchestration simple and sequential unless parallelism is truly necessary

### Persistent session example

First call:

```js
openava.session.counter = (openava.session.counter ?? 0) + 1;
return { counter: openava.session.counter };
```

As long as later calls keep using the same `session_id`, `openava.session.counter` will persist.

### Single-file script example

```json
{
  "script_path": "scripts/summarize.js",
  "input": {
    "path": "notes/today.txt"
  },
  "session_id": "js-summary"
}
```

Use this mode when the logic is already stored in the workspace as a single script file and should run in the same runtime/session model as inline JavaScript.

### Minimal CommonJS example

`scripts/main.js`:

```js
const helper = require("./lib/helper");

module.exports = {
  answer: helper.answer,
  cwd: process.cwd(),
  entry: __filename,
};
```

`scripts/lib/helper.js`:

```js
exports.answer = 42;
```

Notes:

- `require("path")` / `require("node:path")` is supported as a minimal built-in module
- `require()` only supports relative paths like `./x` and `../x`, or absolute paths inside the active workspace
- CommonJS loading is limited to workspace files, with `.js`, `.cjs`, and `index.js` / `index.cjs` fallback
- Inline `code` uses a synthetic entry file named `__openava_inline__.js` rooted at the active workspace for `__filename`, `__dirname`, `process.argv`, and relative `require()`
- Bare package specifiers such as `require("lodash")` are not supported in this minimal version, except for the built-in `path`

## Output Discipline

Prefer returning JSON-serializable values such as:

- objects
- arrays
- strings
- numbers
- booleans
- null

Do not rely on:

- functions as outputs
- class instances
- circular structures
- DOM/browser globals

## Good Patterns

### Deterministic transformation

```js
const rows = openava.input.rows ?? [];
return rows
  .filter(row => row.active)
  .map(row => ({ id: row.id, total: row.price * row.qty }))
  .sort((a, b) => b.total - a.total);
```

### Tool-assisted computation

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

## Decision Rule

Use this skill when code execution improves correctness, repeatability, or compactness.

If JavaScript is not clearly the best execution medium, do not invoke this skill.
