# agent-deck 需求 v2

> 2026-10-29 评审后修订。原版见 [spec-v1.md](spec-v1.md)，验证证据见 [spike-2026-10-29.md](spike-2026-10-29.md)。

## 1. 背景与定位

**痛点**：多个项目、多个会话同时在跑（常态约 18 个 Claude 会话、6 个 Cursor 窗口，其中 2 个是多根 workspace）。agent 在跑的时候，人在另一个 Cursor 窗口。要知道谁在等我，得挨个窗口去看；看到了，还得切回去回复。

**硬约束（使用习惯）**：
- Cursor 三栏布局：左边目录，中间代码，右边 Claude Code 或 Codex 插件。
- 会话留在插件里。
- 一个窗口里开多个会话 tab，靠 tab 标题认会话。

**定位：提醒 + 跳转 + 快答。** 完整对话仍在插件里进行，旁边就有代码和目录。agent-deck 只做三件事：
1. 告诉你哪个会话在等你；
2. 一键把你带到那个会话所在的窗口和 tab；
3. 不需要看代码的事，直接在 deck 里答（快答）。

**不做**：
- 替代插件的聊天界面；
- 管理终端会话或后台会话；
- 伪造用户输入（比如往插件里模拟键入）。

## 2. 功能

### P0：找得到、到得了

1. **会话列表**
   - 只列活着的 Cursor 插件会话：Claude 取 entrypoint=claude-vscode，Codex 取 originator=codex_vscode。
   - 过滤掉 headless 会话（`claude -p` 的 sdk-cli、`codex exec`）和子 agent。
   - 每行显示：
     - 标题（Claude 取 aiTitle，Codex 取会话名或首句）；
     - 所在工作区和项目；
     - 工具；
     - 状态；
     - 最后一条消息摘要；
     - 已等待时长；
     - 权限模式。
2. **状态（按收件箱来分）**
   - 四种状态，排序依次为：**等我处理**（审批或选项题，显示已等待多久）> **新完成、未读** > **在跑** > **已读、空闲**。
   - 可以手动标为已读；在 Cursor 里接着对话，未读会自动清掉。
   - Claude 的状态信号：
     - PermissionRequest（包括 AskUserQuestion）= 等我处理；
     - UserPromptSubmit = 在跑；
     - Stop / StopFailure = 完成；
     - SessionStart / SessionEnd 管会话的起止；
     - 会话注册表里的 busy/idle 兜底。
     - 不用 Notification(permission_prompt)：它要在审批框弹出约 6 秒后才触发。
   - Codex 的状态信号：Codex hooks（SessionStart、UserPromptSubmit、PermissionRequest、Stop）。不用 `notify`：它只能配一个，已经被 Codex Computer Use 占用。
3. **通知**
   - 会话变成“等我处理”或“新完成”时，弹 macOS 通知。
   - 可以直接在通知上操作（见 P1）。
   - 点通知本身就是跳转（见第 4 条）。
4. **精确跳转**
   - 用 `~/.claude/ide/*.lock` 里的 workspaceFolders 找到会话所在的窗口（多根 workspace 也能找到），先把这个窗口拉到前台；
   - 再用插件 URI 聚焦到会话 tab。Claude 的 URI：`cursor://anthropic.claude-code/open?session=<id>`。
   - 不能用 `cursor <cwd>` 直接打开：遇到多根 workspace，它会另开一个新窗口。

### P1：在 deck 里快答

谁先答算谁的：Cursor 里先答了，deck 就撤掉对应的卡片；deck 先答了，Cursor 里的框随之消失。

5. **审批**：展示完整的命令、diff 或文件路径，可以允许或拒绝。
6. **选项题**：展示问题、选项和说明，支持单选和多选。作答方式是 PermissionRequest 返回 `updatedInput.answers`。不要在 PreToolUse 上作答：那样插件里的卡片根本不会出现。
7. **Codex 文字回复**：用 `codex queue --thread <id> --message <text>` 发送，进入会话后就是一条普通的用户消息。
8. **Claude 文字回复**：第一版不提供输入框，只给一个“跳到会话”按钮。回复通道做成可替换的一层，等 Claude 开放 IDE 会话的官方回复入口后再接上。

### 后置

8a. **用量面板**（2026-10-29 加入范围，已实现）：每个额度窗口一条进度条，带重置倒计时，并按最近的消耗速度预测何时用完。数据来源：Claude 用插件自带程序的 `get_usage`，Codex 用 rollout 里的 `rate_limits`。

9. **用量统计**（今天、本周、7 天趋势，按工具、账号、项目分）和**多账号归属**：仍然放到后面做。真要做的时候：
   - 先想清楚要看的是“花了多少钱”还是“额度还剩多少”。
   - 会话记录里不记账号，只能从装上 hook 那一刻起开始记。
   - ccusage 要锁定版本，并且用离线定价。
10. **Codex 选项题**（request_user_input）的代答：还没验证。

## 3. 非功能要求

- **出错时放行（fail-open）**：
  - deck 没在运行或出了异常时，hook 必须在 100ms 内放行，而且不输出任何内容；任何会话都不能因为 deck 卡住。
  - 需要等用户作答的 hook 要有明确的超时上限（比如 10 分钟），一超时就放行，交回 Cursor 处理。
- **性能**：
  - 不需要等待的 hook，单次开销不超过 50ms；
  - matcher 尽量收窄；
  - 纯上报的事件走异步。
- **安全**：
  - deck 能批准任意命令，权限很高。本地通信要用 unix socket（权限 0600），或者用 127.0.0.1 加随机 token，不能监听外网。
  - 审批卡片必须展示完整内容，不能出现“没看内容就批”的情况。
- **数据只留在本机**：
  - 不上传任何数据；
  - 运行时不能从远程拉代码，比如 `npx …@latest`。
- **安装和卸载**：
  - 一条命令完成，合并进现有配置、不覆盖，改之前先备份，卸载后要能逐字节还原（原型见 [spike/probe_install.py](spike/probe_install.py)）。
  - 由用户本人执行：agent 写 Claude 的全局配置会被 auto mode 拦截。
  - Codex 的 hook 装好后，要到 Codex 设置的 Hooks 页手动信任，安装器要提示这一步。hook 内容一改，就要重新信任。
- **兼容和自检**：插件自带的二进制会自动升级，所以每次启动都要检查依赖的几个未公开接口：会话注册表、IDE 锁文件、插件 URI。哪个失效，就降级为“只通知、不跳 tab”，并提示用户。

## 4. 待验证

- URI 落点：先把窗口拉到前台再发 URI，确认 tab 被聚焦，并且没有分叉出新会话。
- Codex 审批：hook 等待期间，插件里会不会同时出现审批框。
- Codex 选项题：能不能由 hook 作答。
- Claude 的 http 类型 hook：deck 没运行时，它会不会放行。

## 5. 相对 v1 的变更

| v1 | v2 | 原因 |
|---|---|---|
| 列出本机所有会话 | 只列活着的 Cursor 插件会话，过滤 headless 会话 | 痛点在插件会话；本机还有定时跑的 `claude -p` |
| 三组状态 | 收件箱四态，加上“未读” | 18 个会话里有 16 个是 idle，“已完成”组会一直很长，起不到提醒作用 |
| Claude 用 Notification 判断“等我” | 用 PermissionRequest | Notification 延迟约 6 秒 |
| Codex 只能判断“完成”，用 notify | 用 Codex hooks，能判断等我处理、在跑、完成 | hooks 已是 stable；notify 已被占用 |
| 配置多个数据目录，按账号统计 | 后置 | 本机只有一个 ~/.claude 和一个 ~/.codex，账号是登出再登录切换的 |
| `cursor <cwd>` 跳转 | 先按 workspace 定位窗口，再用 URI 定位 tab | 2 个窗口是多根 workspace，一个窗口里有多个会话 tab |
| 本地网页或菜单栏 | 菜单栏 + 悬浮面板 + 可直接操作的通知 | 人在另一个窗口，再开一个看板窗口也是切换 |
| 新增 | 在 deck 里审批、答选项题、给 Codex 回文字 | 用户希望不切窗口就能回复 |
| `npx ccusage@latest` | 后置，锁定版本 | 运行时远程拉代码 |
| 开工前先验证 | 已完成，结论见验证报告 | — |
