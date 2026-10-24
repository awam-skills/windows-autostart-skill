# windows-autostart 控制面改造设计

> 日期：2026-10-24  
> 状态：已批准并落地（阶段 0–5 完成，见任务清单）  
> 关联：现有 MVP spec（`.scratch/windows-autostart/spec.md`）、ADR-0001～0006、`CONTEXT.md`

## 1. 背景与目标

### 现状

- CLI 子命令：`recommend` / `add` / `run` / `status` / `uninstall`；无 `list`，无启停/禁用。
- 计划任务落点已配置 `RestartCount=999`、`RestartInterval=1min`（任务级失败重启）。
- MVP Out of Scope 写明：**不做进程守护与持续健康监控**；`status` 仅快照。
- 现网常见形态：业务包另挂手写 `*-watchdog.vbs` / 包外保活任务，未纳入 CLI/技能契约。
- 技能文案与 ADR-0003 对「计划任务失败是否自动回退 Startup」表述不完全一致（技能要求询问用户，ADR 写自动回退）。

### 目标（本改造）

1. **把推荐保活策略做成标准并脚本固化**（含健康检查）。
2. **补齐管理能力**：登记清单、状态、控制（启停/启用禁用）。
3. **增加统一控制层**：健康检查与开发热重载挂在此层，而不是散落在每个业务包。
4. **UI**：托盘进程作为服务端 + 本地 Web 面板。

### 非目标

- Windows Service / 登录前开机 / HKLM / 全用户。
- 审计/清理第三方启动项（Autoruns 类）。
- 复杂日历调度（weekly 等多触发器）——仍属后续 ADR。
- 跨机器远程管理（本机 `localhost` 即可）。

---

## 2. 已确认决策

| 决策点 | 选择 |
|--------|------|
| 保活档位 | **C**：任务 Restart 为基线；**健康检查挂在统一管理/控制层** |
| 架构 | **注册面 + 控制面分层**（下文方案 2） |
| 热重载 | 控制层统一登记监听路径（可多条、可出项目），防抖后分发重启到对应启动项 |
| UI | **托盘（服务端）+ Web 面板** |

---

## 3. 架构

```
┌─────────────────────────────────────────────────────────┐
│  Web 面板 (localhost)     托盘图标 (NotifyIcon)           │
│         └──────────┬──────────────┘                      │
│                    ▼                                       │
│         Control Plane HTTP API                            │
│         (托盘进程内嵌 Kestrel / HttpListener)              │
│                    │                                       │
│         Manager Core（清单 / 探针 / 文件监听 / 控制）       │
│                    │                                       │
│         调用注册面 CLI 或 Task Scheduler API               │
└────────────────────┼──────────────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Registration Plane: windows-autostart.ps1                │
│  recommend / add / run / status / uninstall / list(*)    │
│  包目录 %USERPROFILE%\.win-autostart\<name>\              │
│  落点：scheduled-task（默认）/ startup / run-key          │
└─────────────────────────────────────────────────────────┘
(*) list 属于管理读模型，优先落在控制面；注册面可提供同构 JSON 供 Agent 无 UI 调用。
```

### 3.1 注册面（Registration Plane）

职责不变并小幅加固：

- 唯一写入「业务封装 + 落点」的执行面。
- `add` 对 **scheduled-task** 落点固化保活基线（见 §4）。
- 扩展 manifest schema → `windows-autostart/2`（向后兼容读 v1）。
- 新增只读/控制辅助子命令，供 Agent 与控制面共用（见 §6）。

### 3.2 控制面（Control Plane / Manager）

独立组件，自身也是一条 win-autostart 启动项（名建议：`win-autostart-manager`）：

- 登录后由计划任务拉起（经隐藏入口）。
- 进程内：HTTP API + 托盘 + 可选自动打开/不打开浏览器。
- 拥有：
  - **清单聚合**：扫描 `~\.win-autostart\*`（跳过 `_manager` 元目录）+ 对照计划任务/Startup/Run。
  - **状态**：包装/增强现有 `status`（进程、任务 LastTaskResult、日志尾、健康探针结果）。
  - **控制**：`start` / `stop` / `enable` / `disable` / `restart`。
  - **健康检查循环**：按条目配置周期探测，失败则按策略重启。
  - **热重载监听**：读统一 `watches` 表，`FileSystemWatcher` 多路径，防抖后 `restart` 目标条目。

控制面**不**重新发明业务封装；重启走注册面 `run` 或 `Stop` 进程后再 `run` / `Start-ScheduledTask`。

### 3.3 为何热重载放控制层（而非每任务一个 watcher）

- 监听路径常跨项目、可被多条目共享（例如公共配置）。
- 一处登记、一处开关「开发模式」，避免 N 个常驻 VBS。
- 与健康检查同属「运行时策略」，天然属于控制层。
- 实现：.NET `FileSystemWatcher`（托盘/.NET 宿主）优于再堆一层 VBScript。

---

## 4. 保活标准（脚本固化）

### 4.1 档位定义

| 档位 ID | 名称 | 适用 | 行为 |
|---------|------|------|------|
| `task-restart` | 任务失败重启 | scheduled-task 落点**强制** | `RestartCount=999`，`RestartInterval=1min`，`ExecutionTimeLimit=0`，`MultipleInstances=IgnoreNew`（与现实现一致，写入常量/函数，禁止魔法数散落） |
| `process` | 进程存活 | 控制面可选 | 按 manifest 声明的进程匹配规则（名 + CommandLine 片段）探测；不在则 `restart` |
| `health` | 健康检查 | 控制面可选 | TCP 端口和/或 HTTP(S) URL；连续失败达阈值则 `restart` |
| `watch` | 开发热重载 | 控制面可选 | 文件变更 → 防抖 → `restart`（不替代生产保活） |

默认：`add -Mode logon` + scheduled-task → 仅 `task-restart`。  
`process` / `health` / `watch` 由控制面配置绑定到条目，**不**要求每个包自带 watchdog.vbs。

Startup / Run 落点：无任务 Restart；manifest 标记 `keepalive.taskRestart=false`；控制面仍可挂 `process`/`health`/`watch`（能力降级需在 UI/status 明示）。

### 4.2 重启策略（控制面）

- 冷却：同一条目两次强制重启最小间隔（默认 30s）。
- 抖动：指数退避上限（例如 5min），避免探针误杀风暴。
- 区分：**用户主动 stop/disable** 后，健康循环与 watch **跳过**该条目，直至 enable/start。
- 日志：写入 `~\.win-autostart\_manager\manager.log`。

### 4.3 废弃包外 watchdog

- 迁移指南：`litellm-watchdog.vbs` → 控制面 `process` 规则（匹配 `python.exe` + `litellm`）或 `health`（若代理有固定端口）。
- `add -Force` 重建后不再生成业务专用 watchdog；旧文件由迁移脚本或 uninstall 清理。

---

## 5. 数据模型

### 5.1 条目 manifest（包内 `\<name>.json`）— schema `windows-autostart/2`

保留 v1 字段，新增：

```json
{
  "schema": "windows-autostart/2",
  "name": "litellm-gateway",
  "command": "...",
  "workdir": "",
  "mode": "logon",
  "landing": "scheduled-task",
  "elevated": false,
  "root": "C:\\Users\\...\\.win-autostart\\litellm-gateway",
  "createdAt": "...",
  "keepalive": {
    "taskRestart": true,
    "process": {
      "enabled": false,
      "imageName": "python.exe",
      "commandLineContains": "litellm"
    },
    "health": {
      "enabled": false,
      "intervalSec": 30,
      "failureThreshold": 3,
      "tcpPorts": [4000],
      "http": { "url": "http://127.0.0.1:4000/health", "expectStatus": [200] }
    }
  }
}
```

v1 读取时：默认补全 `keepalive.taskRestart = (landing == scheduled-task)`，其余 enabled=false。

### 5.2 控制面配置（`~\.win-autostart\_manager\`）

| 文件 | 用途 |
|------|------|
| `manager.json` | 监听地址（默认 `127.0.0.1:18765`）、托盘行为、全局默认探针间隔 |
| `watches.json` | 热重载登记表 |
| `state.json` | 运行时：条目 enable 意图、上次重启时间、连续失败计数（可重建） |
| `manager.log` | 控制面日志 |

#### `watches.json` 示例

```json
{
  "schema": "windows-autostart-watches/1",
  "debounceMs": 800,
  "items": [
    {
      "id": "app-config",
      "paths": [
        "D:\\apps\\my-service\\start.py",
        "D:\\apps\\my-service\\models.json"
      ],
      "glob": null,
      "targets": ["my-service"],
      "enabled": true
    }
  ]
}
```

规则：

- `paths` 可为文件或目录；目录可配 `glob`（可选）。
- `targets`：启动项 `name` 列表；变更后对每个 target 执行 `restart`（受冷却约束）。
- 路径允许在封装根目录之外。

### 5.3 归属标记

- 计划任务 Description 继续含 `windows-autostart entry: <name>`。
- 控制面任务：`windows-autostart manager`。
- uninstall 只清理归属可识别项（保持现契约）。

---

## 6. CLI / API 契约

### 6.1 注册面 CLI 增补

| 子命令 | 作用 |
|--------|------|
| `list` | 扫描包根，输出条目数组（name、landing、mode、enabled 线索、schema） |
| `enable -Name` / `disable -Name` | 计划任务：`Enable-ScheduledTask` / `Disable`；Startup：重命名/移出快捷方式（约定 `.disabled`）；Run：删值但保留 manifest 意图 |
| `stop -Name` | 结束业务进程（按 process 规则或任务树）；**不** disable |
| （已有）`run` / `status` / `uninstall` | 保持；`status` 可附带读 control-plane 最近健康快照（若 manager 在跑） |

JSON 信封不变：`command` / `result` / `error` / `data`。

### 6.2 控制面 HTTP API（托盘宿主，仅 localhost）

建议前缀 `/api/v1`：

| 方法 | 路径 | 语义 |
|------|------|------|
| GET | `/entries` | 清单 + 聚合状态 |
| GET | `/entries/{name}` | 单条详情（含健康、日志尾） |
| POST | `/entries/{name}/start` | start/run |
| POST | `/entries/{name}/stop` | stop |
| POST | `/entries/{name}/restart` | restart |
| POST | `/entries/{name}/enable` | enable |
| POST | `/entries/{name}/disable` | disable |
| GET/PUT | `/entries/{name}/keepalive` | 读写 process/health 配置（写回 manifest） |
| GET/PUT | `/watches` | 热重载表 |
| POST | `/watches` | 新增一条 watch |
| DELETE | `/watches/{id}` | 删除 |
| GET | `/health` | manager 自身存活 |

所有写操作：可选简单本地 token（`manager.json` 生成），默认仅绑定 `127.0.0.1`。

Agent 路径：优先 CLI；UI 与托盘走 HTTP。

---

## 7. UI：托盘 + Web 面板

### 7.1 托盘（服务端）

- 技术倾向：**.NET 8+ WinForms/WPF 托盘应用**（或单文件 Publish），内嵌静态 Web 与最小 API；也可用「PowerShell 托盘 + 旁路小 HTTP」但长期维护性较差，**推荐 .NET 宿主**。
- 菜单：打开面板 / 暂停全部探针与 watch（开发总闸）/ 退出（退出是否停业务条目：默认否，仅停 manager）。
- 登录自启：用注册面 `add` 把自己注册为 `win-autostart-manager`。

### 7.2 Web 面板

- 静态前端（简单 SPA 或服务端渲染均可）；默认 `http://127.0.0.1:18765/`。
- 页面：
  1. **清单**：名称、落点、运行状态、健康、操作按钮。
  2. **条目详情**：日志尾、keepalive 配置编辑。
  3. **热重载**：watch 列表增删改、启用开关。
  4. **Manager**：端口、防抖、全局暂停。

### 7.3 技能（Harness）更新

- `SKILL.md`：编排改为「管理类意图走 list/控制面；注册仍走 add」。
- 明确：健康与热重载是控制面职责；禁止再手写包外 watchdog。
- 调和 ADR-0003：默认链失败时 **不静默回退**（与当前 SKILL 一致），需用户确认 `-Landing startup`；另开 ADR-0005 修正。

---

## 8. 与既有 ADR / Spec 的关系

| 文档 | 动作 |
|------|------|
| ADR-0001（技能+CLI） | 保持；补充「控制面为第二交付面，UI 只经控制面」 |
| ADR-0002（时机互斥） | 不变 |
| ADR-0003（默认链） | **重开修正**：失败不静默回退 Startup（对齐现行 SKILL） |
| ADR-0004（当前用户） | 不变；manager 仅 localhost |
| MVP Out of Scope「进程守护」 | **部分收回**：守护/健康/watch 由控制面承担，注册面仍不常驻守护 |
| 新 ADR-0005 | 控制面 + 保活档位 + watches |
| 新 ADR-0006 | 托盘宿主 + localhost Web UI |

---

## 9. 迁移

1. 安装 manager 启动项（`add`）。
2. `list` 识别现有 v1 包，读时升级视图为 v2 默认 keepalive。
3. 对 `litellm-gateway`：录入 process/health；卸载 Startup 侧 watchdog 快捷方式（若有）；删除包内 `litellm-watchdog.vbs`。
4. 黑盒测试：list / enable-disable / health 失败重启 / watch 触发重启 / UI 走通。

---

## 10. 风险与约束

- **权限**：控制面 stop 只能杀当前用户可见进程；提权条目需 Highest 任务上下文。
- **误重启**：健康检查 URL 必须默认可选；空配置不加探针。
- **文件监听风暴**：强制 debounce；目录监听鼓励收窄 glob。
- **端口冲突**：`manager.json` 可改端口；绑定失败托盘气球提示。
- **双实现**：CLI 与 HTTP 必须共用同一 Core 库/模块，避免行为分叉。

---

## 11. 成功标准

- 用户能在 Web/托盘看到全部 win-autostart 条目并启停/禁用。
- 新 `add` 的 scheduled-task 保活参数由单一标准函数写出，可测。
- 可为条目配置 TCP/HTTP 健康检查，失败达阈值自动重启且遵守冷却。
- 可登记多条项目外路径的 watch，变更后目标条目重启。
- 不再依赖业务包内手写 watchdog 作为推荐路径。
- Agent 仅通过 JSON CLI/文档化 API 完成同等操作。

---

## 12. 落地结果

已按阶段完成（详见 `docs/superpowers/plans/2026-10-24-control-plane-tasks.md`）：

1. ADR-0005 / 0006 已写入；ADR-0003 已修正。
2. 实现计划已执行：保活标准 → CLI 管理 → Manager Core → 托盘+Web → 迁移现有包。
3. 版本见 `CHANGELOG.md` `0.5.0`；现网包迁入用 `scripts/migrate-to-scheduled-task.ps1` + Manager keepalive（本机操作记录不入库）。
