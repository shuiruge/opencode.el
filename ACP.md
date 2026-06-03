# OpenCode ACP：AI 编程代理的"对话协议"

> TL;DR：ACP 就是编辑器与 AI 编程代理之间的通话协议。`opencode.el` 用 700 多行 Elisp 帮你实现了这个协议的客户端，让你在 Emacs 里就能跟 AI 实时协作写代码。

---

## 从一个问题开始

你有没有想过：当你在 Emacs 里按下一个键，AI 就开始帮你写代码——**幕后到底发生了什么？**

你的"帮我重构这个函数"这条消息，是怎么从编辑器钻进 AI 的脑袋里，AI 又是怎么把它的一串思考流回你的屏幕的？

答案就是 **ACP**——Agent Collaboration Protocol（代理协作协议）。

## ACP 是什么？用大白话讲

> ACP 是"AI 编程代理"与"编辑器"之间约定的**对话规矩**。

就像两个人打电话需要先拨号、说"喂"、然后才聊正事一样，ACP 规定了：

- **第一句话应该是什么**（初始化）
- **如何建立一条通话线路**（创建会话）
- **如何一边说一边听对方实时回复**（流式响应）
- **如何挂断**（取消/关闭）

它由 JetBrains 和 Zed 共同推动，是编辑器与 AI 代理通信的**开放标准协议**。OpenCode 原生支持它。

## 没有 ACP 会怎样？

举个简单的例子。假如你打开终端，运行：

```bash
opencode "帮我写一个二分查找"
```

它可能等很久，然后一次性输出全部结果。这叫做**同步模式**——你只能等，啥也干不了。

而且，如果你想顺便把当前编辑器里的代码发给它做参考——你要么手动复制粘贴，要么写个脚本读文件。很麻烦，对吧？

ACP 解决了这两个核心问题：

| 问题 | ACP 方案 |
|------|----------|
| **等待响应时卡住** | 流式响应：AI 一边想一边把结果推给你，就像 ChatGPT 逐字输出 |
| **无法传递上下文** | 结构化协议：可以直接把选中的代码、文件路径、甚至错误堆栈一起打包发给 AI |

## ACP 的工作流程：三次握手 + 流式对话

我们可以把 ACP 想象成一次**电话通话**，分为三个阶段：

### 第一阶段：拨号与握手（Initialize）

你的编辑器（作为客户端）对 AI 代理说："喂，我是 emacs-opencode，版本 0.1.0，我想用 ACP 协议 v1 跟你通话，我支持这些能力。"

对应到代码里就是这样（`opencode.el:318-323`）：

```elisp
(opencode--send-request
 "initialize"
 `((protocolVersion . 1)
   (clientCapabilities . ,(make-hash-table :test 'equal))
   (clientInfo . ((name . "emacs-opencode")
                  (version . "0.1.0"))))
 ...)
```

这条消息会通过 stdin（标准输入）发送给 `opencode acp` 子进程。AI 代理通过 stdout（标准输出）回复，告诉编辑器它的版本和功能。

> **你不需要理解 JSON 的细节。** 你只需要知道：编辑器封装好了这一切，你打开 Emacs 按 `M-x opencode`，它自动帮你完成了这个"拨号"步骤。

### 第二阶段：建立会话（session/new）

握手之后，编辑器说："我想新建一个通话线路，工作目录是 `/home/user/project`，没有额外的 MCP 服务器。"

AI 代理回复："好的，这是你的会话 ID：`abc-123`。"

（`opencode.el:340-351`）

这个步骤很关键：**会话（session）** 是 ACP 的基本单位。一个会话绑定了一个工作目录，所有的对话都在这个会话里进行。如果你想切换到另一个项目，就新建一个会话。

### 第三阶段：发消息 & 收回复（session/prompt + 流式通知）

这是最精彩的部分。

当你在 `*opencode*` buffer 里按下 `C-c C-c` 发送 prompt 时，编辑器发出：

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "session/prompt",
  "params": {
    "sessionId": "abc-123",
    "prompt": [
      {"type": "text", "text": "帮我写一个二分查找"}
    ]
  }
}
```

然后 AI 代理开始工作。它不会等你全部想好了再一次性回复，而是**边想边发**：

```
[通知] session/update → 类型: agent_thought_chunk  → "用户想要二分查找..."
[通知] session/update → 类型: agent_thought_chunk  → "二分查找需要有序数组..."
[通知] session/update → 类型: tool_call             → "我要创建一个文件"
[通知] session/update → 类型: agent_message_chunk   → "以下是二分查找的实现..."
[通知] session/update → 类型: tool_call_update      → "文件已创建"
[响应] {stopReason: "finished"}
```

这些"通知"（notification）像流水一样源源不断从 AI 推送到编辑器。编辑器收到一条，就实时渲染到 `*opencode*` 里。**你看到的就是 AI 正在思考的过程。**

（`opencode.el:449-466`）

如果你觉得 AI 想太多了不想看，可以按 `C-c C-t` 关掉思考过程——编辑器会直接跳过 `agent_thought_chunk` 类型的通知。

### 万一想打断怎么办？

发送 `session/cancel` 通知即可：

```elisp
(opencode--send-notification
 "session/cancel"
 `((sessionId . ,opencode--session-id)))
```

这相当于你对 AI 说："行了行了，先到这。"

## 可视化全流程

```
Emacs (opencode.el)                  opencode acp (AI 代理)
      │                                      │
      │  ─── initialize ──────────────────►  │
      │  ◄── {agentInfo, version} ────────── │
      │                                      │
      │  ─── session/new ─────────────────►  │
      │  ◄── {sessionId: "abc-123"} ──────── │
      │                                      │
      │  ─── session/prompt ──────────────►  │
      │  ◄── notify: agent_thought_chunk ─── │  (思考片段)
      │  ◄── notify: agent_thought_chunk ─── │  (思考片段)
      │  ◄── notify: tool_call ───────────── │  (工具调用)
      │  ◄── notify: agent_message_chunk ─── │  (最终回答)
      │  ◄── notify: tool_call_update ────── │  (工具状态变更)
      │  ◄── {stopReason: "finished"} ────── │
      │                                      │
      │  ─── session/cancel ──────────────►  │  (可选取消)
```

## opencode.el 的 ACP 实现骨架

整份协议实现在一个文件里（`opencode.el`，746 行），分为几个清晰的层级：

| 层级 | 做了什么 | 关键词 |
|------|----------|--------|
| **JSON-RPC 层** | 发送请求/通知，解析回复 | `send-request`, `send-notification`, `dispatch-message` |
| **进程管理** | 启停 `opencode acp` 子进程 | `start-process`, `process-filter`, `sentinel` |
| **ACP 协议层** | 初始化、创建会话、发送 prompt | `acp-initialize`, `acp-create-session`, `do-send-prompt` |
| **响应处理** | 渲染流式文本、工具调用状态 | `handle-content-chunk`, `handle-tool-call` |
| **界面** | 对话 buffer、状态栏 | `opencode-mode`, `header-line` |

有趣的是，你甚至不需要理解这个分层。从用户视角看，你只需要记住几个快捷键：

```
M-x opencode          打开 AI 对话
C-c C-c               发送消息
C-c C-k               打断 AI
C-c C-r               选中代码后提问
C-c C-t               开关 thinking 显示
```

剩下的——握手、会话、流式协议——编辑器都替你在幕后搞定了。

## 为什么这很重要？

ACP 代表了一个趋势：**编辑器与 AI 代理之间不再是"你问我答"的单次对话，而是一个持续的协作会话。**

想象一个更高级的场景——你选了一段代码，告诉 AI "给这个函数加单元测试"：
- 上下文（你的代码）通过 `Resource` 内容块一起发送
- AI 边思考边输出测试代码，你实时看到
- AI 调用工具创建文件，你看到状态变化
- 你可以随时打断，调整 prompt 再继续

这在传统的"终端跑一下"模式里几乎不可能优雅地实现。

## 从哪里了解更多？

- [OpenCode 官网](https://opencode.ai)
- [opencode.el GitHub](https://github.com/shuiruge/opencode.el)
- ACP 协议规范（JetBrains / Zed 联合推动）

