帮我做一个本地小工具（macOS，Node + 本地网页或菜单栏都行），用来管理我在 Cursor 里通过 Claude Code 和 Codex 插件开的所有会话。我会同时开多个 Cursor 窗口，不想来回切屏。

需求：
1. 会话总览：列出本机所有 Claude Code 和 Codex 会话，显示项目目录、工具类型、所属账号、最后一条消息和更新时间。
2. 状态分组：分成"等我确认或输入 / 在跑 / 已完成"三组，"等我"的排在最上面。
   - Claude 用 ~/.claude/settings.json 里的 hooks 判断状态：UserPromptSubmit 表示在跑，Notification（permission_prompt|idle_prompt）或 PermissionRequest 表示等我，Stop/StopFailure 表示完成。hook 的输入从 stdin 读，用 session_id 和 cwd 定位会话。
   - Codex 用 config.toml 的 notify，只有 agent-turn-complete 这一个事件，数据是 argv 的最后一个参数（不是 stdin），字段是 kebab-case：thread-id、cwd、last-assistant-message。Codex 只能判断"完成"，不要假装能判断"等我"。
3. 多账号：我的 Claude 和 Codex 都有多个账号会来回切换。支持配置多个数据目录（CLAUDE_CONFIG_DIR / CODEX_HOME）；hook 触发时记录当前登录的是哪个账号，打到会话上。会话列表和用量都能按账号筛选。
4. 通知：会话变成"等我"或"完成"时弹 macOS 通知，点击通知就跳到对应的 Cursor 窗口。
5. 一键跳转：点击某个会话，执行 `cursor <cwd>`，把对应窗口拉到前台。
6. 用量统计：显示今天、本周、7 天趋势的 token 数和估算费用，按工具、账号、项目分开统计。可以复用 ccusage 的逻辑，或者调用 `npx ccusage@latest daily --json`。
7. 安装和卸载：一条命令配好 hooks 和 notify，合并进我现有的配置，不覆盖，改之前先备份，也能一键卸载。
8. 数据只留在本机，不上传。


开工前先验证：在 Cursor 插件里跑一轮对话，确认 hooks 和 notify 会触发。