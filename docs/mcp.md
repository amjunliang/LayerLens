# LayerLens MCP

LayerLens 在 App 进程内提供只读 MCP 服务，不需要独立 sidecar：

```text
http://127.0.0.1:9523/mcp
```

- 传输方式：Streamable HTTP，普通 JSON 响应，不使用 SSE（`GET /mcp` 返回 405）。
- 协议版本：`2025-11-25`、`2025-06-18`、`2025-03-26`、`2024-11-05`。客户端请求的版本受支持时原样返回，否则返回最新版本。`2025-03-26` 的 JSON-RPC 批量请求同样支持。
- 只监听 `127.0.0.1`，校验 `Host` 和 `Origin`，网页无法跨站调用。
- 端口固定为 9523。端口被占用时 LayerLens 无法启动，MCP 也随之不可用。

菜单栏的 LayerLens 图标菜单会显示「MCP: <App> · <设备>」，即 Agent 当前调用 `get_context` 会拿到的目标。

## 一键接入

菜单「LayerLens > MCP 设置…」会检测本机的 Claude Code 和 Codex，点「一键安装」即可。每个客户端分两项，可以单独安装、更新或移除：

| 项 | Claude Code | Codex |
| --- | --- | --- |
| MCP | `claude mcp add --transport http --scope user layerlens <URL>` | `codex mcp add layerlens --url <URL>` |
| Skill | `~/.claude/skills/layerlens/SKILL.md` | `~/.codex/skills/layerlens/SKILL.md` |

- MCP 通过客户端自带的命令修改，LayerLens 不直接编辑它们的配置文件。已配置成其他地址时显示「地址不同」，更新时先移除再添加。
- Claude Code 使用 user scope，所有项目共用；桌面版的 Code 标签页与终端读取同一份配置。桌面版的 Chat 标签页不支持本机 HTTP 地址，不在接入范围内。
- Codex 未单独安装 CLI 时，会使用 ChatGPT 桌面版自带的 `codex`，两者共用 `~/.codex`。
- Skill 文件带有 LayerLens 的标记，只覆盖或删除带标记的版本；同名的其他文件显示「已有同名文件」，不会改动。
- Skill 平时只有名称和描述进入 Agent 上下文，用到时才读取正文。正文说明何时使用 LayerLens、如何用结果搜索源码、如何按需查日志和抓包，以及 MCP 工具不在当前会话时如何用 `curl` 直接调用。
- 首次打开 LayerLens 时，如果检测到客户端但都没有接入，右下角会提示一次。
- 面板中可以开启「登录时启动 LayerLens」。

手动配置时，Claude Code：

```sh
claude mcp add --transport http --scope user layerlens http://127.0.0.1:9523/mcp
```

Codex（`~/.codex/config.toml`）：

```toml
[mcp_servers.layerlens]
url = "http://127.0.0.1:9523/mcp"
```

其他支持 Streamable HTTP 的客户端，按各自格式填入上面的地址即可。

## 连接时机

- Agent 客户端在会话开始时连接 MCP。安装后要新开会话才生效。
- 会话开始时 LayerLens 没有运行，这个会话里就没有 LayerLens 工具：Claude Code 可用 `/mcp` 重连，Skill 也会引导 Agent 改用 `curl`。
- 服务端无状态，不使用 `Mcp-Session-Id`。会话中 LayerLens 重启后，Codex 的下一次调用会自动恢复（已实测）；旧的 `snapshotId` 失效，重新调用 `get_context` 即可。
- Codex 的 `workspace-write` 沙盒默认禁止联网，Skill 中的 `curl` 兜底在 Codex 里一般不可用；Codex 依赖上面的自动恢复。

## 工具

所有工具都声明了 `readOnlyHint: true`。结果是一段紧凑的 JSON 文本，空字段会省略。

| 工具 | 用途 |
| --- | --- |
| `get_context` | 当前窗口的 App、源码目录、选中节点，以及日志和请求数量 |
| `get_canvas_screenshot` | 当前 macOS 窗口的完整可见画布，包含已有选中态 |
| `find_nodes` | 没有选中节点时按文字、类名等搜索 |
| `search_logs` | 按关键词搜索本次启动的日志 |
| `list_requests` | 本次启动的请求列表，每个请求一行 |
| `get_request` | 单个请求的摘要或内容 |

日志和抓包的输出遵循同样的原则：先摘要后细节，过滤在 LayerLens 中完成，用游标只取新增，大内容裁剪，敏感值打码。

### `get_context`

无参数。返回最后获得焦点的 LayerLens 窗口：

```json
{
  "app": "LayerLens Example",
  "bundleId": "com.layerlens.example",
  "sourceRoot": "/Users/me/Workspace/LayerLens",
  "snapshotId": "SNAPSHOT_ID",
  "selected": {
    "element": "UIListContentView._textLabel (UILabel) \"Row 3\"",
    "vc": "LLEListViewController"
  },
  "activity": { "logs": 1280, "requests": 42, "failedRequests": 2 }
}
```

| 字段 | 说明 |
| --- | --- |
| `app` / `bundleId` | 当前窗口选中的 App |
| `sourceRoot` | App 源码所在的 Git 仓库根目录；不在仓库中时为源文件所在目录 |
| `snapshotId` | 传给 `find_nodes`，固定本次窗口和 App |
| `selected.element` | `ivar (类名) "文字" · id=accessibilityIdentifier`，各部分没有时省略。优先使用声明在业务类中的 ivar，没有时退回系统类的；文字超过 40 个字符时截断，前缀仍可用于搜索 |
| `selected.owner` | 最近的业务代码祖先类 |
| `selected.vc` | 最近的 ViewController |
| `activity` | 本次启动的日志条数 `logs`、请求数 `requests`、失败请求数 `failedRequests`；为 0 时省略。没开抓包时带 `networkCapture: "off"` |

- 没有选中节点时不返回 `selected`。
- 窗口里没有选中 App 时返回错误 `no_app_selected`，不生成快照。

### `get_canvas_screenshot`

传入 `get_context` 返回的 `snapshotId`，返回一张 MCP `image/png` 图片。画面来自 LayerLens macOS 窗口中当前可见的画布，包含画布已有的选中态。用户要求看画面，或需要判断裁切、遮挡、对齐等视觉问题时调用。

如果快照对应的画布不在可截图的 macOS 窗口中，返回 `canvas_unavailable`。

### `find_nodes`

在 `snapshotId` 固定的窗口和 App 中搜索节点：

```json
{
  "snapshotId": "SNAPSHOT_ID",
  "query": "立即阅读",
  "visibleOnly": true,
  "limit": 5
}
```

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `snapshotId` | string，必填 | `get_context` 返回的值 |
| `query` | string，必填 | 文字、类名、ivar 或 accessibility identifier |
| `visibleOnly` | boolean，默认 `true` | 跳过隐藏和屏幕外节点 |
| `limit` | integer 1–10，默认 5 | 返回候选数 |

返回 `{ "nodes": [...] }`，每个候选与 `selected` 相同，只有 `element`、`owner`、`vc`，按可信度排序。参数类型不对或有未知参数时返回 `invalid_arguments`。没有合适的选中节点时，Agent 应使用候选 `element` 中的 ivar、类名或 identifier 在 `sourceRoot` 中搜索源码。

### `search_logs`

```json
{ "snapshotId": "SNAPSHOT_ID", "query": "error|timeout", "limit": 50 }
```

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `snapshotId` | string，必填 | `get_context` 返回的值 |
| `query` | string | 与日志面板搜索相同：`\|` 分隔的关键词，不区分大小写；以 `\` 开头为正则。省略时返回最新的日志 |
| `cursor` | integer | 上次返回的 `cursor`，只返回之后的新日志 |
| `limit` | integer 1–200，默认 50 | 返回行数 |

返回：

```json
{
  "lines": "14:03:22.118 load failed: timeout ×3\n14:03:25.004 retry ok",
  "cursor": 1311,
  "matched": 4,
  "omittedOlder": 12
}
```

- 只包含 App 本次启动的日志。每条一行，时间在前，由旧到新；连续相同的内容合并为 `×N`；超过 200 个字符截断，换行显示为 `⏎`。
- `matched` 是匹配的条数，超出 `limit` 时返回最新的部分，`omittedOlder` 为省略的行数。
- 让用户复现问题后，传入上次的 `cursor` 只看新日志。

### `list_requests`

```json
{ "snapshotId": "SNAPSHOT_ID", "failedOnly": true }
```

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `snapshotId` | string，必填 | `get_context` 返回的值 |
| `query` | string | 匹配方法、状态码、URL 和错误，规则同 `search_logs` |
| `failedOnly` | boolean，默认 `false` | 只返回状态码 ≥ 400 或失败的请求 |
| `inBody` | boolean，默认 `false` | 同时搜索最新 300 个请求的响应内容，需要 `query` |
| `cursor` | integer | 上次返回的 `cursor`，只返回之后的新请求 |
| `limit` | integer 1–100，默认 20 | 返回行数 |

返回：

```json
{
  "host": "api.example.com",
  "lines": "#41 GET 200 120ms /v1/books?page=2 2.0KB json\n#42 POST 500 312ms /v1/order html",
  "cursor": 42,
  "matched": 2
}
```

- 每个请求一行：`#id 方法 状态码 耗时 路径 响应大小 类型`。进行中的状态码为 `…`，失败为 `ERR` 并附 `error=`。
- 所有请求同一域名时，域名只在 `host` 中给出一次，行内只写路径。
- 没开抓包且没有记录时返回 `network_capture_off`；没开抓包但已有记录时返回结果并带 `capture: "off"`。

### `get_request`

```json
{ "snapshotId": "SNAPSHOT_ID", "id": 42, "part": "response", "path": "data.items[0]" }
```

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `snapshotId` | string，必填 | `get_context` 返回的值 |
| `id` | integer，必填 | `list_requests` 中 `#` 后面的数字 |
| `part` | `summary` / `request` / `response`，默认 `response` | 摘要、请求内容或响应内容 |
| `path` | string | 只取 JSON 中的一部分，如 `data.items[0].title` |
| `maxChars` | integer 200–8000，默认 2000 | 内容的最大字符数 |

- `summary` 返回方法、URL、状态码、耗时、大小、类型、错误和请求/响应头。
- `Authorization`、`Cookie`、`Set-Cookie`、`X-API-Key` 以及名称包含 token、secret、password、session 的头和 JSON 字段显示为 `*** (N chars)`。
- JSON 内容只保留结构：数组保留前 2 项并注明总数（只多 1 项时全部保留），字符串超过 200 个字符截断，6 层以下折叠。需要更多细节时用 `path` 取子树，而不是加大 `maxChars`。裁剪后放得下时 `body` 直接是 JSON 值；超过 `maxChars` 时截成文本并带 `truncated`。
- 文本内容按 `maxChars` 截断；二进制内容只返回大小和类型。
- 内容不可读时返回 `body_unavailable` 并说明原因：没有内容、超过 5 MB 未保存、以流的方式发送、文件内容未保存、已被缓存清理，或还没从 App 取回（稍后重试）。

## 并发与失效

- 每个 Agent 的 `get_context` 会固定一个窗口快照，后续查询不跟随其他窗口的焦点变化。
- 窗口关闭、切换 App 或 App 重启后返回 `snapshot_stale`，重新调用 `get_context` 即可。
- 快照 1 小时后过期，返回 `snapshot_not_found`。
- 日志和抓包工具只读取本次启动的数据；App 重启后快照失效，重新调用 `get_context`。
- `find_nodes` 整次请求限时 8 秒，App 不响应时返回 `target_timeout`；App 未连接或在后台时返回 `target_unavailable`。
- 所有工具只读，不注入触摸，也不控制设备。
