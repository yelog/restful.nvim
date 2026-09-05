# Index Path Consistency Implementation Plan

> 按任务顺序实施，每一步先验证再继续。仅在用户明确授权后修改实现；未经要求不执行 commit 或 push。若执行环境提供 executing-plans 技能，按该技能逐项执行。

**Goal:** 消除全量扫描后保存文件产生的新旧接口重复，确保同一文件始终只有一份最新解析报告。

**Architecture:** 在索引层统一绝对路径的词法规范化，候选发现、解析、文件缓存和增量失效使用同一种文件身份。保留按文件整体替换报告的架构，不在 picker 或 endpoint ID 上掩盖陈旧数据。路径修复作为第一阶段独立交付，扫描期间保存文件的一致性作为第二阶段单独加固。

**Tech Stack:** Lua、Neovim headless、ripgrep、现有 Spring provider/fallback parser、Lua assertion 测试。

---

## 已确认事实

- `lua/restful/index.lua` 的 `candidate_files()` 和 `discover()` 将 rg 输出的 `./...` 与 root 拼接，未规范化。
- `refresh_file()` 和 `invalidate()` 使用规范化路径，所以同一文件可能出现两个 `state.files` 键。
- `rebuild()` 聚合所有文件报告，仅按 endpoint ID 去重。
- Spring ID 包含文件路径、注解行号和方法行号；删注释会使新旧 ID 更加不同。
- 使用实际 Feign 目录全量扫描后刷新一个未修改文件，接口数从 11 增至 13。
- 当前增量测试只从 `refresh_file()` 建立初始状态，未覆盖全量到增量的过渡。
- 当前测试脚本的 `+luafile ... +qa!` 不能作为 assertion 失败退出码的可靠保证。

## 范围与约束

- 第一阶段只修改 `lua/restful/index.lua` 和相关索引测试。
- 不修改业务仓库 Java 文件，不改变 Javadoc 规则、Feign 分类、HTTP 方法或请求行为。
- 不修改 `model.stable_id()`、Spring ID、picker 去重或展示逻辑。
- 不按 URL 合并不同文件的接口，不把方法名或 description 当唯一键。
- 不引入依赖、磁盘缓存、符号链接解析或新的公共配置。
- 规范化使用绝对路径加 `vim.fs.normalize()`，不使用 `fs_realpath()`；已删除文件也必须有可计算的键。
- 保持现有根目录语义，包括 `/` 等边界；不要在复用 helper 时扩大既有根目录问题。
- 未保存 buffer 的实时索引不在范围内，索引仍读取磁盘。
- 测试 fixture 使用临时目录和独立样例，不依赖用户业务路径或中文描述原文。

## 文件清单

| 文件 | 第一阶段操作 |
| --- | --- |
| `lua/restful/index.lua` | 统一发现、解析、缓存和失效路径 |
| `tests/restful_incremental_spec.lua` | 全量转增量及描述删除回归 |
| `tests/restful_async_spec.lua` | 异步发现、解析规范化与重复候选 |
| `tests/restful_index_spec.lua` | 同步候选输出和缓存路径契约 |
| `tests/restful_index_state_spec.lua` | 第二阶段才扩展提交一致性测试 |
| `lua/restful/providers/java/spring.lua` | 只读，确认 ID 和描述行为 |
| `lua/restful/picker.lua` | 只读，通过 `item_for()` 验证展示数据 |

## 第一阶段：路径身份修复

### Task 1: 建立基线并固化最小失败用例

**Files:** `tests/restful_incremental_spec.lua`。

1. 执行 `git status --short`，记录工作区状态，不覆盖他人修改。
2. 运行现有索引相关测试并记录基线，使用下方严格退出码命令。
3. 在临时目录构造 `SysMenuClient.java`，包含带 `@description: Menu configuration` 的 `findByMenuType` 和一个无关接口。
4. 使用真实 `index.scan_root(root, { provider = "spring" })` 建立全量状态；测试要求 rg 可用，缺失时明确报告环境限制。
5. 先不修改文件，调用 `index.refresh_file(path, opts)`，断言报告数和接口数不增加。该用例应在当前实现失败。
6. 增加独立场景：初次全量扫描后删除 description 行，再刷新；断言只存在一个目标路由、`description == nil`、显示名为 `findByMenuType`，且导航行号更新。
7. 使用 `index._reset()` 隔离场景，清理临时目录；优先复用现有 fixture 辅助函数，不引入测试框架。

严格执行单个测试：

```sh
nvim --headless -u NONE '+lua local ok, err = pcall(dofile, "tests/restful_incremental_spec.lua"); if not ok then print(err); vim.cmd("cquit 1") end' '+qa!'
```

**Expected:** 修复前因重复报告或重复接口断言失败，不能是 parser 缺失、语法错误或模块路径错误。

### Task 2: 统一同步路径与文件报告键

**Files:** `lua/restful/index.lua`、`tests/restful_index_spec.lua`。

1. 增加一个私有 helper，不导出新公共 API：

```lua
local function normalize_path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end
```

2. `candidate_files()` 先将 root 转成绝对规范路径，再将每个 rg 相对结果与 root 拼接并规范化。相对结果必须相对于扫描 root，而不是任意当前目录。
3. `fallback_files()` 从规范化 root 出发，确保没有 rg 时也返回同一类规范路径；保持原有排除规则。
4. `scan_root()` 在调用 scanner 和写入 `state.files` 之前使用同一个规范路径。即使未来发现器实现变化，索引写入边界也不接收路径别名。
5. `refresh_file()`、`invalidate()`、`root_for_path()` 改为复用 helper；`normalize_root()` 可复用绝对路径部分，但保留现有 root 处理契约。
6. 不修改 `state.files[path] = report` 的替换语义；由 `rebuild()` 自动移除旧 endpoint。
7. 在同步索引测试中断言候选路径精确等于预期绝对路径，且报告键、`report.path`、handler/declaration 文件路径一致。
8. 运行 Task 1 测试和 `tests/restful_index_spec.lua`，预期通过。

**关键约束:** 不能只规范化 table key，却仍将带 `/./` 的路径传给 scanner，否则 ID 和导航路径仍不一致。

### Task 3: 覆盖异步发现与解析边界

**Files:** `lua/restful/index.lua`、`tests/restful_async_spec.lua`。

1. 使用现有 `opts.system` 注入方式，模拟 rg 返回 `./src/A.java`；调用原始 `discover()`，通过 `vim.wait()` 等待 scheduled callback，断言输出是规范绝对路径。
2. 模拟输出带空格的文件名，确认没有按空白拆分路径；不改变以换行分隔的现有协议。
3. 向 `parse_candidates()` 注入同一个文件的规范路径与 `/./` 别名，使用现有 `schedule` 和 `scan_path` 注入统计调用次数。
4. 断言 scanner 收到的路径、`working.files` 键全部规范化；同一规范文件仅扫描一次、仅流式发出一次。
5. 在 `discover()` 中复用与同步发现相同的绝对路径规则。
6. 在 `parse_candidates()` 获取 candidate 后立即规范化；用局部已处理文件集合消除路径别名。不得仅依赖 `working.files[path]`，否则读取失败的重复候选仍会重试并重复诊断。
7. 保留按 endpoint ID 去重，用来处理不同报告中的重复 endpoint；文件去重与 endpoint 去重各自负责不同层次。
8. 保留取消、时间预算让出、回调完成一次的行为；重复文件跳过也需要遵循批次时间预算。
9. 运行 `tests/restful_async_spec.lua`，确认原有流式、取消和让出测试不回归。

**Expected:** 正常异步索引不会产生带 `/./` 的缓存键；直接调用解析入口也不能绕过规范化契约。

### Task 4: 扩展文件级替换测试矩阵

**Files:** `tests/restful_incremental_spec.lua`、`tests/restful_async_spec.lua`。

1. 在已有 fixture 上增加以下用例，每个用例单独初始化索引，避免错误状态相互抵消。
2. 对关键场景同时检查 endpoint 数量、文件报告数量、描述和 handler/declaration 位置，不只检查 URL。
3. 至少一个用例走真实异步 `discover → parse_candidates → commit` 后再刷新文件，不能只测试同步 `scan_root()`。
4. 通过 `picker.item_for(endpoint)` 检查搜索文本已使用方法名、不包含旧描述；不需要启动 Snacks UI。

| 操作 | 预期 |
| --- | --- |
| 全量后刷新未改动文件 | 报告数和接口数不变 |
| 删除 description 行 | 只有最新记录，回退方法名 |
| 只修改 description 内容 | 名称更新，即使 ID 未变也不能显示旧描述 |
| 插入空行使声明移动 | 只有最新位置 |
| 修改路由 | 旧路由不存在，新路由存在 |
| 删除单个接口 | 其他接口保留 |
| 移除文件所有映射 | 该文件 endpoint 全部移除 |
| 删除文件后调用刷新入口 | 旧报告和 endpoint 移除；不在本阶段新增删除事件监听 |
| 两个不同文件声明同一 URL | 两个合法接口均保留 |
| 多次交替使用规范路径和 `/./` 别名刷新 | 始终只有一个文件报告 |
| 一个文件刷新 | 其他文件的数据保持不变 |

### Task 5: 验证、升级边界与交付

**Files:** 第一阶段改动文件；不修改业务源码。

1. 执行全部测试，每个文件在独立 Neovim 进程运行，并强制传播失败退出码：

```sh
for test_file in tests/*_spec.lua; do
  RESTFUL_TEST_FILE="$test_file" nvim --headless -u NONE '+lua local ok, err = pcall(dofile, vim.env.RESTFUL_TEST_FILE); if not ok then print(err); vim.cmd("cquit 1") end' '+qa!' || exit 1
```

2. 若安装 StyLua，针对修改的 Lua 文件运行 `stylua --check`；区分既有格式问题和新增问题，避免全仓库重排。
3. 执行 `git diff --check`、`git diff --stat` 并审查完整 diff。
4. 对实际 Feign 目录执行只读 headless 复测：全量索引后刷新 `SysMenuClient.java`，计数必须保持不变；不硬编码目录接口总数为 11。
5. 业务描述删除场景在临时 fixture 或内存数据中验证，不自动编辑业务 Java 文件。
6. 重启加载新版插件的 Neovim，重新搜索，验证没有重复结果、跳转正确、Controller 条目仍保留。若无法操作真实 UI，明确标记待手工验收。
7. 旧缓存仅存在进程内，不做迁移或路径别名兼容层。升级推荐重启；仅 `:RestfulRefresh` 不会重新加载已经 require 的 Lua 模块。
8. 输出测试结果、跳过项、改动范围和第二阶段剩余风险，不自动提交。

**第一阶段完成标准:** 同步和异步全量扫描后保存文件都不新增重复报告；新旧内容按文件整体替换；其他文件与合法重复 URL 不受影响；全部严格测试通过或明确列出既有失败。

## 第二阶段：扫描期间保存的一致性加固

本阶段不是路径重复修复的前置条件，建议单独实施和审查。第一阶段完成后，可以先交付根因修复，再继续此阶段；不为了消除 `/./` 扩大第一阶段 diff。

### Task 6: 用确定性调度复现旧快照覆盖

**Files:** `tests/restful_async_spec.lua`、`tests/restful_index_state_spec.lua`。

1. 使用现有可注入 scheduler 将全量扫描暂停在已经解析 A、尚未解析 B 的位置，不通过 sleep 猜测时序。
2. 修改临时文件 A，执行 `invalidate()` 或 `refresh_file()`，然后继续旧全量扫描。
3. 断言最终 A 为最新内容、B 完整保留，索引不能在只有局部文件时提前成为可复用的 ready。
4. 分别覆盖防抖回调先于提交、晚于提交，以及连续两次保存 A。
5. 扩展已有 generation 测试，确保旧 generation 不提交、不清空新 generation 的失效信息。
6. 在实现前确认测试稳定失败，并记录错误究竟是旧内容回写、脏标记丢失还是提前 ready。

### Task 7: 保留脏文件并在发布前补扫

**Files:** `lua/restful/index.lua`，上述异步和状态测试。

1. 推荐采用“活动全量扫描的脏文件集合 + 提交前补扫”，而不是每保存一次就重扫整个大型项目。
2. 将活动扫描所需的脏文件信息与防抖队列区分；防抖消费不能清除尚未被活动扫描吸收的变更。
3. `invalidate()` 和直接 `refresh_file()` 都需要让活动扫描获知文件变化，所有标记仍使用第一阶段规范路径。
4. 全量扫描完成基础解析后，使用原有时间预算机制补扫脏文件，将报告整体替换进 working；删除文件则移除 working 中旧报告。
5. 补扫期间再次保存的文件进入下一轮；只有脏文件已处理且 generation 仍有效时才发布 ready 快照。检查和最终提交之间不能让出事件循环。
6. 从最终 `working.files` 重建 endpoints、diagnostics 和 frameworks，不在旧 endpoint 数组上增量追加。
7. 增量刷新不能把活动且尚不完整的全量索引提前标为 ready。旧完整快照可保留，但不能冒充最新完整结果。
8. generation 切换、取消、失败和 `_reset()` 必须释放或隔离活动状态，防止迟到回调污染新扫描。
9. 不仅给 `refresh_file()` 增加 generation 自增：这会使当前扫描失效，却不自动保证有完整替代快照。
10. 运行 Task 6 测试，再执行第一阶段全部验证。

**展示边界:** 流式 finder 已发送给当前 picker 的条目不能通过最终 cache commit 自动撤回。第二阶段至少保证最终缓存及重新打开搜索使用最新完整快照；当前已打开 picker 的实时替换不是默许支持。如果需要扫描过程中当前窗口也立即替换旧结果，应另行验证 Snacks 重启 finder 的机制，不能向现有列表再追加一个“新版”条目来伪装更新。

**第二阶段完成标准:** 任意受测保存时序不会让旧快照覆盖新文件，不丢失脏标记，不将不完整索引标为 ready；取消和旧 generation 隔离正常；重新打开 picker 读取最新完整快照。

## 实施顺序与交付节点

1. Task 1：锁定可重复失败，确认修复目标。
2. Task 2–3：完成同步、异步路径一致性最小实现。
3. Task 4–5：完成回归与第一阶段交付。
4. Task 6–7：独立实施并发一致性加固，不阻塞路径修复发布。

本计划不包含提交或推送操作。每个交付节点汇报实际完成范围和证据，不能将计划中的验证写成已经通过。
