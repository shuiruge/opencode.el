;;; opencode.el --- Emacs integration for OpenCode via ACP  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: opencode.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: ai, tools, convenience
;; URL: https://github.com/shuiruge/opencode.el

;; This file is NOT part of GNU Emacs.

;; Provides Emacs integration with OpenCode (https://opencode.ai) using
;; the Agent Client Protocol (ACP).  No external dependencies beyond
;; built-in Emacs libraries.
;;
;; Quick start:
;;   M-x opencode                Start or switch to the *opencode* buffer
;;   M-x opencode-send-prompt    Send a prompt (reads from minibuffer)
;;   M-x opencode-ask            With region active, ask about selected code
;;   M-x opencode-cancel         Cancel the current operation
;;
;; With a region selected in any buffer, M-x opencode-ask sends the
;; selected text as context to OpenCode along with your question.

;;; Code:

(require 'json)

(defgroup opencode nil
  "Integration with the OpenCode AI coding agent."
  :group 'external
  :prefix "opencode-")

(defcustom opencode-executable "opencode"
  "Path to the opencode executable."
  :type 'file
  :group 'opencode)

(defcustom opencode-buffer-name "*opencode*"
  "Name of the OpenCode interaction buffer."
  :type 'string
  :group 'opencode)

(defcustom opencode-args '("acp")
  "Arguments passed to `opencode-executable' for the ACP subprocess."
  :type '(repeat string)
  :group 'opencode)

(defface opencode-user-face
  '((t :inherit bold :foreground "#4EC9B0"))
  "Face for user messages."
  :group 'opencode)

(defface opencode-agent-face
  '((t :inherit bold :foreground "#569CD6"))
  "Face for agent messages."
  :group 'opencode)

(defface opencode-thought-face
  '((t :inherit shadow :italic t))
  "Face for agent thought chunks."
  :group 'opencode)

(defcustom opencode-show-thoughts nil
  "If non-nil, display the model's internal thinking/reasoning.
The thinking text is shown with `opencode-thought-face' (italic shadowed)."
  :type 'boolean
  :group 'opencode)

(defface opencode-tool-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool call status."
  :group 'opencode)

(defvar opencode--process nil
  "ACP subprocess object.")

(defvar opencode--session-id nil
  "Current ACP session ID (string).")

(defvar opencode--rpc-id 0
  "Next JSON-RPC request ID.")

(defvar opencode--rpc-callbacks nil
  "Alist of (id . FUNCTION) for pending request callbacks.")

(defvar opencode--accumulator nil
  "Buffer for accumulating incomplete stdout lines.")

(defvar opencode--pending-prompt nil
  "Non-nil while awaiting a session/prompt response.")

(defvar opencode--response-start nil
  "Marker at the start of the current streaming response.")

(defvar opencode--ready nil
  "Non-nil when initialized and session is active.")

(defvar opencode--tool-status nil
  "Alist of (tool-call-id . (title . status)) for active tool calls.")

(defvar opencode--tool-markers nil
  "Alist of (tool-call-id . marker) for tool status lines.")

(defvar opencode--cwd nil
  "Working directory for the current session.")

(defvar opencode--shutting-down nil
  "Non-nil during intentional shutdown (suppresses sentinel warnings).")

(defvar opencode--last-chunk-type nil
  "Type of the last content chunk (\\='thought or \\='message).")

(defvar opencode--pending-queue nil
  "Queue of (prompt-text context-text context-filename) waiting for session.")

(defvar opencode--status "disconnected"
  "Visible status string shown in the header line.
One of: \"disconnected\", \"connecting\", \"ready\", \"processing\".")

(defun opencode--json-encode (data)
  "Encode DATA to a JSON string with default settings."
  (let ((json-encoding-pretty-print nil)
        (json-encoding-fringep nil)
        (json-encoding-separator ","))
    (json-encode data)))

(defun opencode--json-decode (string)
  "Decode STRING as JSON, returning an alist."
  (condition-case nil
      (json-read-from-string string)
    (error nil)))

(defun opencode--json-get (key alist)
  "Get KEY (a symbol) from ALIST."
  (cdr (assq key alist)))

(defun opencode--process-send (string)
  "Send STRING followed by newline to the ACP subprocess."
  (when (process-live-p opencode--process)
    (process-send-string opencode--process string)
    (process-send-string opencode--process "\n")))

(defun opencode--acc-buffer ()
  "Get or create the accumulator buffer."
  (or (and (buffer-live-p opencode--accumulator) opencode--accumulator)
      (setq opencode--accumulator
            (generate-new-buffer " *opencode-acc*"))))

(defun opencode--process-filter (proc string)
  "Accumulate and parse newline-delimited JSON from ACP process."
  (when (buffer-live-p (opencode--acc-buffer))
    (with-current-buffer (opencode--acc-buffer)
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      (while (re-search-forward "\n" nil t)
        (let ((line (buffer-substring-no-properties (point-min) (1- (point)))))
          (delete-region (point-min) (point))
          (opencode--handle-raw-message line))))))

(defun opencode--process-sentinel (proc event)
  "Handle ACP process termination."
  (when (string-match-p "finished\\|exited\\|killed\\|abnormal\\|failed" event)
    (let ((status (process-exit-status proc)))
      (setq opencode--process nil
            opencode--ready nil
            opencode--session-id nil
            opencode--pending-prompt nil
            opencode--status "disconnected")
      (opencode--update-header)
      (when (get-buffer opencode-buffer-name)
        (with-current-buffer (get-buffer opencode-buffer-name)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\n;; ACP process exited (status %d)\n" status)))))
      (unless opencode--shutting-down
        (when (and status (/= 0 status))
          (display-warning 'opencode
            (format "OpenCode ACP process exited with status %d" status)
            :warning))))))

(defun opencode--start-process ()
  "Start the ACP subprocess."
  (when (process-live-p opencode--process)
    (delete-process opencode--process))
  (when (buffer-live-p opencode--accumulator)
    (kill-buffer opencode--accumulator))
  (setq opencode--status "connecting")
  (opencode--update-header)
  (setq opencode--rpc-callbacks nil
        opencode--rpc-id 0
        opencode--session-id nil
        opencode--pending-prompt nil
        opencode--ready nil
        opencode--tool-status nil
        opencode--tool-markers nil)
  (let* ((process-connection-type nil)
         (proc (make-process
                :name "opencode-acp"
                :buffer nil
                :command (cons opencode-executable opencode-args)
                :filter #'opencode--process-filter
                :sentinel #'opencode--process-sentinel
                :stderr (generate-new-buffer " *opencode-stderr*")
                :noquery t
                :coding 'utf-8-emacs-unix)))
    (setq opencode--process proc)
    proc))

(defun opencode--stop-process ()
  "Stop the ACP subprocess and clean up."
  (setq opencode--shutting-down t)
  (when (process-live-p opencode--process)
    (delete-process opencode--process))
  (when (buffer-live-p opencode--accumulator)
    (kill-buffer opencode--accumulator))
  (setq opencode--process nil
        opencode--session-id nil
        opencode--ready nil
        opencode--pending-prompt nil
        opencode--rpc-callbacks nil
        opencode--tool-status nil
        opencode--tool-markers nil
        opencode--status "disconnected"
        opencode--shutting-down nil)
  (opencode--update-header))

(defun opencode--send-request (method params &optional callback)
  "Send a JSON-RPC request.  If CALLBACK is given, call it with (RESULT ERROR) upon response."
  (setq opencode--rpc-id (1+ opencode--rpc-id))
  (let ((id opencode--rpc-id))
    (when callback
      (push (cons id callback) opencode--rpc-callbacks))
    (opencode--process-send
     (opencode--json-encode
      `((jsonrpc . "2.0")
        (id . ,id)
        (method . ,method)
        (params . ,params))))
    id))

(defun opencode--send-notification (method params)
  "Send a JSON-RPC notification (no response expected)."
  (let ((msg (opencode--json-encode
              `((jsonrpc . "2.0")
                (method . ,method)
                (params . ,params)))))
    (opencode--process-send msg)))

(defun opencode--handle-raw-message (line)
  "Parse and dispatch a single JSON-RPC message LINE."
  (condition-case err
      (let ((msg (opencode--json-decode line)))
        (when msg
          (opencode--dispatch-message msg)))
    (error
     (display-warning 'opencode
       (format "JSON parse error: %s\nLine: %s"
               (error-message-string err) (truncate-string-to-width line 120))
       :debug))))

(defun opencode--dispatch-message (msg)
  "Dispatch a parsed JSON-RPC message."
  (let* ((id (opencode--json-get 'id msg))
         (method (opencode--json-get 'method msg))
         (result (opencode--json-get 'result msg))
         (error-obj (opencode--json-get 'error msg)))
    (cond
     ((and id (not method))
      (let ((pair (assq id opencode--rpc-callbacks)))
        (when pair
          (setq opencode--rpc-callbacks (delq pair opencode--rpc-callbacks))
          (funcall (cdr pair) result (and error-obj
                                          (opencode--json-get 'message error-obj))))))
     ((and method (not id))
      (opencode--handle-notification method (opencode--json-get 'params msg)))
     (error-obj
      (message "OpenCode RPC error: %s" (opencode--json-get 'message error-obj))))))

(defun opencode--handle-notification (method params)
  "Handle a JSON-RPC notification."
  (pcase method
    ("session/update"
     (opencode--handle-update params))
    (_
     (message "OpenCode: unhandled notification: %s" method))))

(defun opencode--acp-initialize ()
  "Initialize the ACP connection."
  (opencode--send-request
   "initialize"
   `((protocolVersion . 1)
     (clientCapabilities . ,(make-hash-table :test 'equal))
     (clientInfo . ((name . "emacs-opencode")
                    (version . "0.1.0"))))
   (lambda (result error-msg)
     (if error-msg
         (opencode--buffer-insert
          (format ";; Initialize failed: %s\n" error-msg))
       (opencode--on-initialized result)))))

(defun opencode--on-initialized (result)
  "Handle the initialize response."
  (let ((agent-info (opencode--json-get 'agentInfo result))
        (auth-methods (opencode--json-get 'authMethods result))
        (caps (opencode--json-get 'agentCapabilities result)))
    (opencode--buffer-insert
     (format ";; OpenCode %s\n"
             (or (opencode--json-get 'version agent-info) "connected")))
    (opencode--acp-create-session)))

(defun opencode--acp-create-session ()
  "Create a new ACP session."
  (let ((cwd (or opencode--cwd default-directory)))
    (opencode--send-request
     "session/new"
      `((cwd . ,cwd)
        (mcpServers . []))
     (lambda (result error-msg)
       (if error-msg
           (opencode--buffer-insert
            (format ";; Session creation failed: %s\n" error-msg))
         (opencode--on-session-ready result))))))

(defun opencode--on-session-ready (result)
  "Handle the session/new response."
  (setq opencode--session-id (opencode--json-get 'sessionId result)
        opencode--ready t
        opencode--status "ready")
  (opencode--update-header)
  (opencode--buffer-insert
   (format ";; Session: %s\n" opencode--session-id))
  (opencode--buffer-insert ";; Ready.\n")
  (when opencode--pending-queue
    (opencode--buffer-insert ";; Processing queued prompts...\n")
    (let ((queue (nreverse opencode--pending-queue)))
      (setq opencode--pending-queue nil)
      (dolist (args queue)
        (apply #'opencode--send-prompt-internal args)))))

(defun opencode--do-send-prompt (prompt-text &optional context-text context-filename)
  "Send PROMPT-TEXT to the current ACP session.
Queues the prompt if the session is still initializing.
Optional CONTEXT-TEXT and CONTEXT-FILENAME provide file context."
  (cond
   ((not opencode--ready)
    (push (list prompt-text context-text context-filename) opencode--pending-queue)
    (opencode--buffer-insert
     (format ";; Queued: \"%s\" (connecting)...\n"
             (truncate-string-to-width prompt-text 60 nil nil t)))
    (opencode--ensure-connected))
   (opencode--pending-prompt
    (user-error "Already waiting for a response"))
   (t
    (opencode--send-prompt-internal prompt-text context-text context-filename))))

(defun opencode--send-prompt-internal (prompt-text &optional context-text context-filename)
  "Internal: actually send the prompt (session is ready)."
  (setq opencode--pending-prompt t
        opencode--tool-status nil
        opencode--tool-markers nil
        opencode--last-chunk-type nil
        opencode--status "processing")
  (opencode--update-header)
  (let ((inhibit-read-only t))
    (let* ((content-blocks
            (append
             (when (and context-text (not (string-blank-p context-text)))
               (list
                `((type . "resource")
                  (resource . ((uri . ,(concat "file:///"
                                               (or context-filename "*selection*")))
                               (mimeType . "text/plain")
                               (text . ,context-text))))))
             (list `((type . "text") (text . ,prompt-text)))))
           (_ (opencode--buffer-insert-user-message prompt-text context-text))
         (start (with-current-buffer (get-buffer-create opencode-buffer-name)
                  (let ((inhibit-read-only t))
                    (goto-char (point-max))
                    (let ((p (point-marker)))
                      (opencode--insert-header "OpenCode" 'opencode-agent-face)
                      p)))))
    (setq opencode--response-start start)
    (opencode--send-request
       "session/prompt"
       `((sessionId . ,opencode--session-id)
         (prompt . ,content-blocks))
       (lambda (result error-msg)
         (opencode--on-prompt-done result error-msg))))
    (opencode--scroll-to-bottom)))

(defun opencode--on-prompt-done (result error-msg)
  "Handle the session/prompt response."
  (let ((stop-reason (and result (opencode--json-get 'stopReason result))))
    (when (and error-msg (not (string-blank-p error-msg)))
      (opencode--buffer-insert
       (format ";; Error: %s\n" error-msg)))
    (setq opencode--pending-prompt nil
          opencode--response-start nil
          opencode--tool-status nil
          opencode--tool-markers nil
          opencode--status "ready")
    (opencode--update-header)))

(defun opencode-cancel ()
  "Cancel the current prompt turn."
  (interactive)
  (when (and opencode--session-id opencode--pending-prompt)
    (opencode--send-notification
     "session/cancel"
     `((sessionId . ,opencode--session-id)))
    (message "Cancelling...")))

(defun opencode--handle-update (params)
  "Handle a session/update notification."
  (let* ((update (opencode--json-get 'update params))
         (type (opencode--json-get 'sessionUpdate update)))
    (pcase type
      ("agent_message_chunk"
       (opencode--handle-content-chunk update 'opencode-agent-face))
      ("agent_thought_chunk"
       (when opencode-show-thoughts
         (opencode--handle-content-chunk update 'opencode-thought-face)))
      ("tool_call"
       (opencode--handle-tool-call update))
      ("tool_call_update"
       (opencode--handle-tool-call-update update))
      ("user_message_chunk"
       nil)
      (_
       nil))))

(defun opencode--handle-content-chunk (update face)
  "Append a content chunk from UPDATE to the buffer using FACE."
  (let* ((content (opencode--json-get 'content update))
         (type (opencode--json-get 'type content))
         (text (opencode--json-get 'text content)))
    (when (and (string= type "text") text)
      (with-current-buffer (get-buffer-create opencode-buffer-name)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (when (and (eq face 'opencode-agent-face)
                     (eq opencode--last-chunk-type 'thought))
            (insert "\n"))
          (setq opencode--last-chunk-type
                (if (eq face 'opencode-thought-face) 'thought 'message))
          (insert (propertize text 'face face))
          (opencode--scroll-to-bottom))))))

(defun opencode--handle-tool-call (update)
  "Handle a tool_call update."
  (let* ((tool-id (opencode--json-get 'toolCallId update))
         (title (or (opencode--json-get 'title update) ""))
         (status (or (opencode--json-get 'status update) "pending")))
    (with-current-buffer (get-buffer-create opencode-buffer-name)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (let ((marker (point-marker)))
          (insert (propertize (format "  [%s] %s\n" status title)
                              'face 'opencode-tool-face))
          (setq opencode--tool-markers
                (cons (cons tool-id marker)
                      (assq-delete-all tool-id opencode--tool-markers)))
          (setq opencode--tool-status
                (cons (cons tool-id (cons title status))
                      (assq-delete-all tool-id opencode--tool-status)))
          (opencode--scroll-to-bottom))))))

(defun opencode--handle-tool-call-update (update)
  "Handle a tool_call_update notification."
  (let* ((tool-id (opencode--json-get 'toolCallId update))
         (new-status (or (opencode--json-get 'status update) "")))
    (setq opencode--tool-status
          (let ((existing (assq tool-id opencode--tool-status)))
            (if existing
                (setcdr existing (cons (car (cdr existing)) new-status))
              (cons (cons tool-id (cons "" new-status)) opencode--tool-status))))
    (let ((marker (cdr (assq tool-id opencode--tool-markers))))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (marker-buffer marker)
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char marker)
              (let* ((existing (assq tool-id opencode--tool-status))
                     (entry (cdr existing))
                     (title (car entry)))
                (delete-region (line-beginning-position) (line-end-position))
                (insert (propertize (format "  [%s] %s" new-status title)
                                    'face 'opencode-tool-face))
                (insert "\n"))))
          (opencode--scroll-to-bottom))))))

(define-obsolete-function-alias 'opencode--handle-tool-status
  'opencode--handle-tool-call-update "0.1")

(defun opencode--insert-header (label face)
  "Insert a message header with LABEL using FACE."
  (let ((inhibit-read-only t)
        (time (format-time-string "%H:%M:%S")))
    (insert "\n\n" (propertize (format "<<< %s [%s] >>>\n" label time)
                             'face face))
    (insert "\n")))

(defun opencode--buffer-insert (text)
  "Insert TEXT into the opencode buffer at the end."
  (when (get-buffer opencode-buffer-name)
    (with-current-buffer (get-buffer opencode-buffer-name)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert text)
        (opencode--scroll-to-bottom)))))

(defun opencode--buffer-insert-user-message (prompt-text &optional context-text)
  "Insert the user's PROMPT-TEXT and optional CONTEXT-TEXT into the buffer."
  (with-current-buffer (get-buffer-create opencode-buffer-name)
    (let ((inhibit-read-only t))
      (opencode--insert-header "You" 'opencode-user-face)
      (when (and context-text (not (string-blank-p context-text)))
        (insert (propertize
                 (format "  [Context]:\n%s\n--\n" context-text)
                 'face 'opencode-thought-face)))
      (insert prompt-text "\n"))))

(defun opencode--scroll-to-bottom ()
  "Scroll the opencode buffer to show the latest content."
  (when (get-buffer-window opencode-buffer-name)
    (with-current-buffer opencode-buffer-name
      (when (get-buffer-window (current-buffer))
        (with-selected-window (get-buffer-window (current-buffer))
          (goto-char (point-max))
          (recenter -1))))))

(defun opencode--ensure-buffer ()
  "Ensure the opencode buffer exists and is in opencode-mode."
  (let ((buffer (get-buffer-create opencode-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'opencode-mode)
        (opencode-mode))
      (setq buffer-read-only t))
    buffer))

(defun opencode--ensure-connected ()
  "Ensure the ACP process is running and a session exists."
  (unless (process-live-p opencode--process)
    (let ((buffer (opencode--ensure-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (if (= (point) (point-min))
              (insert ";; Starting OpenCode ACP...\n")
            (insert "\n;; Starting OpenCode ACP...\n")))))
    (opencode--start-process)
    (opencode--acp-initialize)))

(defvar-keymap opencode-mode-map
  :doc "Keymap for opencode-mode."
  "C-c C-c" #'opencode-send-prompt
  "C-c C-k" #'opencode-cancel
  "C-c C-r" #'opencode-ask
  "C-c C-q" #'opencode-quit
  "C-c C-x" #'opencode-cancel
  "C-c C-l" #'opencode-clear
  "C-c C-p" #'opencode-send-prompt
  "C-c C-t" #'opencode-toggle-thoughts
  "g"        #'opencode
  "?"        #'opencode-help)

(defun opencode--update-header ()
  "Refresh the header line with current status."
  (when (get-buffer opencode-buffer-name)
    (with-current-buffer (get-buffer opencode-buffer-name)
      (when (derived-mode-p 'opencode-mode)
        (let* ((status-str
                (pcase opencode--status
                  ("disconnected" "[--]")
                  ("connecting"   "[...]")
                  ("ready"        "[ok]")
                  ("processing"   "[**]")
                  (_ (format "[%s]" opencode--status))))
               (status-face
                (pcase opencode--status
                  ("connecting" 'warning)
                  ("ready"      'success)
                  ("processing" 'opencode-thought-face)
                  (_ 'font-lock-comment-face)))
               (key-hints
                (substitute-command-keys
                 "\\<opencode-mode-map>\
C-c C-c: send | C-c C-k: cancel | C-c C-r: ask | C-c C-t: thoughts | C-c C-q: quit")))
          (setq-local header-line-format
                      (list " " (propertize status-str 'face status-face)
                            "  " key-hints)))))))

(define-derived-mode opencode-mode special-mode "OpenCode"
  "Major mode for interacting with OpenCode AI coding agent.

Commands:
\\{opencode-mode-map}"
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (opencode--update-header))

(defun opencode-help ()
  "Show help for opencode-mode."
  (interactive)
  (describe-function 'opencode-mode))

;;;###autoload
(defun opencode ()
  "Start OpenCode and switch to the *opencode* buffer."
  (interactive)
  (opencode--ensure-buffer)
  (opencode--ensure-connected)
  (pop-to-buffer opencode-buffer-name))

;;;###autoload
(defun opencode-send-prompt (prompt)
  "Send a PROMPT to OpenCode.  Interactively, reads from the minibuffer."
  (interactive
   (list (read-string "OpenCode prompt: " nil 'opencode-prompt-history)))
  (when (string-blank-p prompt)
    (user-error "Empty prompt"))
  (opencode)
  (opencode--do-send-prompt prompt)
  (when opencode--ready
    (message "Sent: %s" (truncate-string-to-width prompt 50 nil nil t))))

;;;###autoload
(defun opencode-ask (beg end)
  "Ask OpenCode about the selected region.
With no active region, falls back to `opencode-send-prompt'."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (list nil nil)))
  (if (not (and beg end))
      (call-interactively #'opencode-send-prompt)
    (let* ((text (buffer-substring-no-properties beg end))
           (filename (or (buffer-file-name) (buffer-name)))
           (prompt (read-string
                    (format "Ask about region (%d chars): " (length text))
                    nil 'opencode-prompt-history)))
      (opencode)
      (opencode--do-send-prompt prompt text filename)
      (when opencode--ready
        (message "Sent to OpenCode with %d chars of context." (length text))))))

;;;###autoload
(defun opencode-toggle-thoughts ()
  "Toggle display of model thinking/reasoning content."
  (interactive)
  (setq opencode-show-thoughts (not opencode-show-thoughts))
  (message "OpenCode thoughts: %s"
           (if opencode-show-thoughts "shown" "hidden"))
  (opencode--update-header))

;;;###autoload
(defun opencode-clear ()
  "Clear the *opencode* buffer."
  (interactive)
  (let ((buffer (get-buffer opencode-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (delete-region (point-min) (point-max))
          (insert (format ";; Buffer cleared\n")))))))

;;;###autoload
(defun opencode-quit ()
  "Kill the OpenCode buffer and process."
  (interactive)
  (opencode--stop-process)
  (let ((buffer (get-buffer opencode-buffer-name)))
    (when buffer
      (kill-buffer buffer))))

;;;###autoload
(defun opencode-restart ()
  "Restart the OpenCode ACP process."
  (interactive)
  (opencode--stop-process)
  (opencode)
  (message "OpenCode restarted."))

;;;###autoload
(defun opencode-set-cwd (dir)
  "Set the working directory for the current session and reconnect."
  (interactive "DDirectory: ")
  (setq opencode--cwd (expand-file-name dir))
  (opencode-restart))

(defun opencode--auto-start-p (filename)
  "Maybe auto-start opencode for certain file types."
  nil)

(provide 'opencode)

;;; opencode.el ends here
