# PRD: opencode.el — Emacs 集成 OpenCode

## 概述

在 Emacs 中与 [OpenCode](https://opencode.ai) AI 编程代理交互，通过 ACP（Agent Client Protocol）协议通信。零外部依赖，仅使用 Emacs 内置库实现。

## 用户需求

1.  **在 Emacs 中启动 opencode** — 像在终端中运行 `opencode` 一样，在 Emacs 中启动并与之交互。
2.  **发送选中内容作为上下文** — 将当前 buffer 中选中的代码/文本发送给 opencode，作为指令的上下文参照。
3.  **状态可见性** — 在处理过程中（思考/回答）显示状态标记，回答完成后提示用户可继续提问。
4.  **Thinking 内容控制** — 可选择显示或隐藏模型的内部推理过程（thinking）。

## 方案选择：ACP（Agent Client Protocol）

使用 `opencode acp` 命令以 ACP 协议通信，而非在终端中模拟运行 TUI。

**理由：**

| 方案 | 优点 | 缺点 |
|------|------|------|
| `opencode acp` (ACP) | 异步、流式响应、结构化上下文、编辑器原生协议 | 需实现 JSON-RPC 客户端 |
| `M-x shell` / `ansi-term` | 实现简单 | 无流式、无法结构化传递上下文 |
| `opencode run` (CLI) | 简单 | 同步、非交互式 |

ACP 是编辑器与 AI 代理通信的开放标准协议（由 JetBrains 和 Zed 共同推动），OpenCode 原生支持。

## 架构

### 通信模型

```
Emacs (opencode.el)  ──stdin/stdout──►  opencode acp
                     ◄──JSON-RPC 2.0────
```

- 传输层：stdio，换行分隔的 JSON-RPC 2.0 消息
- 每行一条完整的 JSON 消息（`\n` 分隔）
- 请求与回复通过 `id` 字段匹配
- 通知（无 `id`）由 Agent 主动推送

### 协议流程

```
Client                          Agent
  │                               │
  ├── initialize ────────────────►│
  │◄── result {protocolVersion} ──┤
  │                               │
  ├── session/new ───────────────►│
  │◄── result {sessionId} ────────┤
  │                               │
  ├── session/prompt ────────────►│
  │◄── notification: update ──────┤  (agent_thought_chunk)
  │◄── notification: update ──────┤  (agent_message_chunk)
  │◄── notification: update ──────┤  (tool_call / tool_call_update)
  │◄── result {stopReason} ───────┤
```

### 文件结构

单文件包：`opencode.el`

| 层次 | 组件 | 职责 |
|------|------|------|
| JSON-RPC | `opencode--send-request` | 发送请求，注册回调 |
| | `opencode--send-notification` | 发送通知 |
| | `opencode--dispatch-message` | 按 `id`/`method` 分发消息 |
| 进程管理 | `opencode--start/stop-process` | 管理 ACP 子进程 |
| | `opencode--process-filter` | 解析换行分隔的 JSON |
| | `opencode--process-sentinel` | 处理进程退出 |
| ACP 协议 | `opencode--acp-initialize` | 初始化连接 |
| | `opencode--acp-create-session` | 创建会话 |
| | `opencode--do-send-prompt` | 发送 prompt（含排队逻辑） |
| 响应处理 | `opencode--handle-content-chunk` | 追加流式文本（区分 thinking/message） |
| | `opencode--handle-tool-call` | 显示工具调用状态 |
| | `opencode--on-prompt-done` | 响应完成处理 |
| UI | `opencode-mode` | major mode，`*opencode*` buffer |
| | `opencode--update-header` | header-line 状态指示器 |
| 用户命令 | `opencode` | 打开/启动 |
| | `opencode-send-prompt` | 发送 prompt |
| | `opencode-ask` | 选中区域+提问 |
| | `opencode-toggle-thoughts` | 切换 thinking 显示 |

## 功能规格

### 1. ACP 连接

- 启动：`opencode acp` 作为 Emacs 子进程运行
- 初始化：自动完成 `initialize` → `session/new`
- 重连：进程崩溃后自动提示，支持 `M-x opencode-restart`
- 工作目录：通过 `opencode--cwd` 或 `default-directory` 设置

### 2. Prompt 处理

- **即时发送**：session 就绪时立即发送 prompt
- **排队发送**：session 未就绪时自动排队，就绪后自动发送
- **并发控制**：`opencode--pending-prompt` 防止重复发送
- **取消**：通过 `session/cancel` 通知取消当前请求

### 3. 流式响应

- `agent_thought_chunk`：模型的内部推理（可选显示）
- `agent_message_chunk`：模型的最终回答
- `tool_call` / `tool_call_update`：工具调用及其状态
- 所有内容实时追加到 `*opencode*` buffer，自动滚到底部

### 4. 上下文发送

选中区域通过 `ContentBlock::Resource` 发送：

```json
{
  "type": "resource",
  "resource": {
    "uri": "file:///path/to/file.el",
    "mimeType": "text/x-emacs-lisp",
    "text": ";; selected region content"
  }
}
```

支持：
- 文件路径（`buffer-file-name`）
- MIME 类型自动推断（基于 major mode）
- 区域文本作为 resource 内容

### 5. 状态指示

`header-line` 显示当前状态：

| 状态 | 显示 | 触发时机 |
|------|------|----------|
| 未连接 | `[--]` (comment face) | 进程未启动 / 已断开 |
| 连接中 | `[...]` (warning face) | 子进程启动，等待初始化 |
| 就绪 | `[ok]` (success face) | session 创建完成 |
| 处理中 | `[**]` (thought face) | prompt 发出，等待响应 |

### 6. Thinking 控制

- **`opencode-show-thoughts`**：自定义变量，默认 `nil`
- **`C-c C-t`** / `M-x opencode-toggle-thoughts`：交互式开关
- 关闭时 `agent_thought_chunk` 完全跳过，不占用 buffer

### 7. 关键绑定

```
C-c C-c   opencode-send-prompt    发送 prompt
C-c C-k   opencode-cancel         取消当前请求
C-c C-r   opencode-ask            选中区域并提问
C-c C-t   opencode-toggle-thoughts  切换 thinking 显示
C-c C-l   opencode-clear          清空 buffer
C-c C-q   opencode-quit           退出并关闭进程
```

### 8. 自定义选项

```elisp
opencode-executable     ;; "opencode"，可执行文件路径
opencode-buffer-name    ;; "*opencode*"，buffer 名称
opencode-args           ;; '("acp")，子进程参数
opencode-show-thoughts  ;; t，显示 thinking 内容
```

## 边际情况处理

| 场景 | 行为 |
|------|------|
| 进程未就绪时发送 prompt | 自动排队，就绪后发送 |
| 进程崩溃 | `opencode--update-header` 显示 `[--]`，可手动重启 |
| 两次 prompt 重叠 | `user-error "Already waiting for a response"` |
| buffer 只读 | 所有写入使用 `inhibit-read-only t` |
| 进程退出 | sentinel 清理状态，设 `opencode--ready = nil` |
| 重复 `initialize` | `opencode--ensure-connected` 仅在进程未运行时调用 |

## 非目标

- 不实现完整的 ACP 客户端（只实现最小必要子集）
- 不支持多会话管理
- 不支持 image/audio 内容类型
- 不依赖第三方 Emacs 包
