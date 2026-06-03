# opencode.el — Emacs Integration for OpenCode

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

🀄[中文版](README-zh.md)

opencode.el is an Emacs package that interacts with the [OpenCode](https://opencode.ai) AI coding agent via the **ACP (Agent Client Protocol)**. Zero external dependencies — built entirely with Emacs built-in libraries.

## Installation

Add `opencode.el` to your `load-path` and require it:

```elisp
(require 'opencode)
```

Or with `use-package`:

```elisp
(use-package opencode
  :load-path "/path/to/opencode.el"
  :bind (("C-c o" . opencode)))
```

## Project Structure

```
opencode.el/
├── opencode.el        # Emacs Lisp client implementation (ACP protocol)
├── opencode.el.org    # Literate programming document (Org Mode, tangle-able)
├── ACP.md             # ACP protocol explanation (Chinese)
├── PRD.md             # Product requirements document (Chinese)
├── README.md          # This file
└── README-zh.md       # Chinese README
```

## Usage

```elisp
M-x opencode
```

Opens the `*opencode*` buffer. Type a prompt and press `C-c C-c` to send, or select a region and press `C-c C-r` to ask about it.

### Keybindings

| Key | Command | Description |
|-----|---------|-------------|
| `C-c C-c` | `opencode-send-prompt` | Send prompt |
| `C-c C-k` | `opencode-cancel` | Cancel current request |
| `C-c C-r` | `opencode-ask` | Ask about selected region |
| `C-c C-t` | `opencode-toggle-thoughts` | Toggle thinking display |
| `C-c C-l` | `opencode-clear` | Clear the buffer |
| `C-c C-q` | `opencode-quit` | Quit and close process |

### Customization

```elisp
(setq opencode-show-thoughts t)  ;; show thinking by default (default: nil)
(setq opencode-executable "opencode")  ;; path to the opencode binary
```

## Author

OpenCode

## License

MIT
