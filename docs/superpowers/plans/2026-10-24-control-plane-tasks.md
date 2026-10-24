# windows-autostart 控制面改造 — 任务清单与开工规划

> 日期：2026-10-24  
> 设计依据：`docs/superpowers/specs/2026-10-24-control-plane-design.md`  
> 状态：阶段 0–5 全部完成；已 Fast-forward 合入本地 `main`（`b31ceee`，不走 PR）  
> 执行方式：本地分支开发，完成后合并回 `main`

## 开工顺序（硬约束）

用户指定落地顺序：

1. **保活策略标准 + 脚本固化**
2. **CLI 管理能力**（登记清单 / 状态 / 控制）
3. **UI**（托盘服务端 + Web 面板）

控制面 Core（健康循环、watches）跨在 1～2 与 3 之间：探针与 watch **逻辑**在阶段 1～2 以可测模块落地，**托盘宿主与面板**在阶段 3 挂载。

---

## 阶段 0 — 文档与决策落盘（设计批准后立刻做）

- [x] 0.1 将本设计与任务清单拷入技能仓库 `docs/superpowers/`
- [x] 0.2 新增 ADR-0005（控制面 + 保活档位 + watches）
- [x] 0.3 新增 ADR-0006（托盘 + localhost Web）
- [x] 0.4 修正 ADR-0003：默认链失败不静默回退 Startup
- [x] 0.5 更新 `CONTEXT.md`：增加 Control Plane、Keepalive tier、Watch、Manager 等词条
- [x] 0.6 更新 `.scratch/.../spec.md`：收回「进程守护」禁令中由控制面承担的部分；标明 UI
- [x] 0.7 更新 `SKILL.md` 命令表与编排（list/enable/disable/stop；管理意图走控制面）

**阶段出口**：仓库文档与 ADR 与设计一致，无实现代码要求。

---

## 阶段 1 — 保活标准固化（注册面）

目标：scheduled-task 保活参数单一实现；manifest v2；去掉「包外手写 watchdog」作为推荐路径。

- [x] 1.1 抽出 `New-AutostartTaskSettings`（或等价）常量：RestartCount=999、Interval=1min、ExecutionTimeLimit=0、MultipleInstances=IgnoreNew、电池策略、Hidden
- [x] 1.2 黑盒/单元：断言 `add` 写入的计划任务 settings 符合标准
- [x] 1.3 Manifest schema → `windows-autostart/2`，读写兼容 v1
- [x] 1.4 `keepalive` 默认块写入（taskRestart 随 landing）
- [x] 1.5 文档：Startup/Run 无 taskRestart；能力降级说明
- [x] 1.6 （可选同期）定义 process/health 字段校验，但注册面 **不**启动循环

**阶段出口**：新注册任务保活可测且一致；旧包可读。

---

## 阶段 2 — CLI 管理能力

目标：无 UI 也能清单 + 控制；为控制面/Agent 提供同构 JSON。

- [x] 2.1 `list`：扫描 `~\.win-autostart\*`（排除 `_manager`），输出数组
- [x] 2.2 `enable` / `disable`：按 landing 分支实现（任务 / Startup 快捷方式约定 / Run）
- [x] 2.3 `stop`：按 process 规则或任务关联进程结束；用户 disable 意图写入可观测状态
- [x] 2.4 `status` 增强：反映 enabled、若存在 manager 快照则附带
- [x] 2.5 黑盒：list → disable → status → enable → run → uninstall 幂等
- [x] 2.6 更新 ParamSpec / SKILL 命令表 / evals 触发词

**阶段出口**：CLI 可管理本机现有两项（asr / litellm）。

---

## 阶段 3 — Manager Core（无 UI）

目标：健康检查与热重载在控制层可运行、可测（可先用 `manager` 子命令或独立 `win-autostart-manager` 控制台宿主）。

- [x] 3.1 `_manager` 目录与 `manager.json` / `watches.json` / `state.json` 契约
- [x] 3.2 清单聚合服务（复用 list）
- [x] 3.3 重启管线：`restart` + 冷却 + 退避 + 尊重 disable
- [x] 3.4 Health loop：TCP / HTTP，failureThreshold
- [x] 3.5 Watch loop：多路径 FileSystemWatcher + debounce + targets 分发
- [x] 3.6 本地 HTTP API（§6.2）最小实现（可先无托盘）
- [x] 3.7 用注册面把自己注册为 `win-autostart-manager` 的脚本/文档
- [x] 3.8 测试：模拟端口失败触发重启；摸文件触发 restart；disable 后不重启

**阶段出口**：无浏览器也能 curl API 完成健康与热重载。

---

## 阶段 4 — 托盘 + Web 面板

目标：托盘宿主承载 API；Web 完成日常管理。

- [x] 4.1 .NET 托盘项目骨架（单文件发布目标）
- [x] 4.2 内嵌/托管静态前端 + 复用阶段 3 API
- [x] 4.3 清单页：状态与 start/stop/restart/enable/disable
- [x] 4.4 条目详情：日志尾、keepalive 编辑
- [x] 4.5 热重载页：CRUD watches
- [x] 4.6 托盘菜单：打开面板 / 全局暂停探针与 watch / 退出
- [x] 4.7 仅绑定 127.0.0.1；端口冲突提示
- [x] 4.8 手工验收清单（中文）写入 `docs/`

**阶段出口**：用户只用面板即可管理条目与热重载。

---

## 阶段 5 — 迁移与收尾

- [x] 5.1 迁移 `litellm-gateway`：配置 process/health；移除 `litellm-watchdog.vbs` 及 Startup 侧残留
- [x] 5.2 `asr-to-openai`：确认 task-restart；按需加 health
- [x] 5.3 `migrate-to-scheduled-task.ps1` 与技能说明对齐新模型
- [x] 5.4 回归黑盒 + 技能 evals
- [x] 5.5 版本号与 CHANGELOG（若有）

**阶段出口**：迁移助手 + 技能文案不再推荐包外 watchdog；设计成功标准全部勾上。

---

## 建议工期切分（供规划，非承诺）

| 阶段 | 大致体量 |
|------|----------|
| 0 文档 | 小 |
| 1 保活固化 | 小～中 |
| 2 CLI 管理 | 中 |
| 3 Manager Core | 大 |
| 4 托盘+Web | 大 |
| 5 迁移 | 小～中 |

批准设计后，阶段 1 单独出详细 writing-plans（逐步可测）；阶段 3/4 可再拆子计划。

---

## 明确不做（本轮）

- 机器级 / Service / 非 localhost 暴露
- 每条目独立 VBS 超级 watchdog 作为默认
- 复杂日历 schedule 扩展
