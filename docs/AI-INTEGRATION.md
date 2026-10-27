# AI integration / AI 接入说明

[English README](../README.md) · [中文 README](../README.zh-CN.md)

## Configuration and helper

When AI protection is enabled, SleepControl merges its own hook entries into:

- Codex: `~/.codex/hooks.json`, or the directory selected by `CODEX_HOME`.
- Claude Code: `~/.claude/settings.json`, or the directory selected by `CLAUDE_CONFIG_DIR`.

It keeps other entries and stores backups under `~/Library/Application Support/LidControl/AI/`. Malformed configuration is reported instead of being overwritten. The helper and its English/Chinese resource bundle are installed in that same state directory, so moving the project folder does not break the hooks.

Commands end with `# sleepcontrol-ai-observer` and call `SleepControlHelper`. The earlier `lidcontrol-ai-observer` entries are migrated. The old helper may remain so clients that have not reloaded their configuration can still report events.

The Codex `/hooks` list groups entries by event name. Open an event, then inspect the command. `Unnamed hook` can still be the correct entry. Review and trust each SleepControl entry; do not bypass Codex's trust mechanism. A change to the helper path or hook command may require a new review. Fully reopening a client is the fallback when new entries are not visible.

开启 AI 保护时，应用会合并自己的钩子，保留其他配置，并将原文件备份到本地状态目录。Codex 中按事件打开命令详情，认准 `SleepControlHelper` 和 `sleepcontrol-ai-observer`，再信任所有相关条目。找不到新配置时，完整退出并重新打开客户端；不要把 `/clear` 当成配置已重新加载的证明。

## Local status readers

Hooks report task lifecycle events. To distinguish active work from waits for input or approval, the app also reads local client status:

- **Codex:** connects to the existing Unix-domain control socket at `app-server-control/app-server-control.sock` under the Codex configuration directory. It performs a WebSocket handshake and uses read-only calls to list loaded threads, read their status, and list background terminals. It does not start or resume threads, take over subscriptions, or answer approvals. The implementation was developed against the Codex CLI 0.163.0 schema; this is a compatibility reference, not a requirement that users install that exact version.
- **Claude Code:** reads local session registry files for the `2.1.x` format. Hooks add task and subtask detail. These files are not a stable public API; unsupported formats are reported as unknown rather than being treated as finished. The format was checked with 2.1.303 and 2.1.305 during development.

A disconnected or unknown status preserves an existing sleep-protection decision until detection recovers or AI protection is disabled. A Codex session without the shared local service, for example a `--no-daemon` session, cannot be guaranteed to report approval waits accurately using hooks alone.

钩子之外，应用还读取本机客户端状态，判断它是在工作还是等待你操作。Codex 使用已有的本机共享服务；Claude Code 读取目前支持的 `2.1.x` 会话状态文件。这些接口可能随客户端升级变化。遇到未知状态时，应用不会把失联当成任务结束。

## Desktop and remote tasks

Desktop Code sessions can be detected when they execute on this Mac, use the same configuration directory, and expose the corresponding local status or hooks. Check a real task through its running, waiting, and finished states after setup or a client update.

Regular Claude chat, Cowork, cloud-only work, and remote SSH execution are outside the guaranteed scope. Already-running background work that has not reported its state may need a new local session before it can be tracked completely.

桌面版需要在本机执行并能传回相应状态。建议用一个真实任务检查执行、等待输入和结束三个阶段。普通聊天、Cowork、云端和远程 SSH 任务不能保证识别。

## State, recovery, and testing

The app, hook helper, and monitoring process share an atomic JSON state file protected by a process lock. Only session/task identifiers, lifecycle state, and process identity are retained. Prompt text, responses, and tool arguments are not stored.

Closing the AI switch stops it from changing power settings; installed hooks can still update local state. Normal application exit restores the power setting owned by AI protection. If the UI process exits unexpectedly, the independent monitor handles already-registered tasks before restoring settings and exiting.

Tests can isolate state with `SLEEPCONTROL_STATE_DIRECTORY`. The legacy name `LIDCONTROL_STATE_DIRECTORY` is still accepted. These overrides are for testing or explicit custom deployments; they are not required for normal use.

## Source references

- [Codex hooks](https://learn.chatgpt.com/docs/hooks)
- [Codex app server](https://learn.chatgpt.com/docs/app-server)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
