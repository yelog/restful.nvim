# Spring Javadoc Display Name Implementation Plan

> Execute this plan task-by-task, reviewing each test result before proceeding. Do not commit or push unless the user explicitly requests it.

**Goal:** 修复 Spring API 名称显示为 `/` 的问题，正确提取 Javadoc 正文或 `@description`，无有效描述时回退到方法名。

**Architecture:** 在 Spring provider 的 `javadoc_description` 内完成注释边界清理与内容选择，保留现有 endpoint 数据结构、描述注解优先级及 picker 回退逻辑。通过公开的 `spring.extract` 和 `picker.display_name` 验证结果，不导出私有函数，也不新增通用注释解析框架。

**Tech Stack:** Lua、Neovim headless、Java Tree-sitter、现有 Java fallback parser、仓库 Lua assertion 测试。

---

## 范围与事实

- 已确认 `lua/restful/providers/java/spring.lua:84` 先删除前导 `*`，导致结束符 `*/` 残留 `/`。
- 已确认同文件第 85 行过滤所有块标签，包括业务代码中的 `@description:`。
- 已确认 `lua/restful/picker.lua:44-46` 优先使用 description，因此错误字符串阻止方法名回退。
- 现有 `tests/restful_spring_spec.lua` 通过，但未覆盖 Javadoc 描述提取。
- 不修改业务 Java 文件，不改变路由、HTTP 方法、Feign 分类、参数解析、索引结构或公共 API。
- 不在 picker 中增加 `description == "/"` 特判；在数据来源处消除分隔符残留。
- 不引入依赖，不升级解析器，不解析完整 Javadoc/HTML，不展开继承文档或内联标签。

## 名称选择契约

名称优先级为：现有 API 描述注解 > Javadoc 正文首段 > 首个非空 `@description` > Java 方法名 > `<anonymous>`。

- 描述注解沿用当前 `annotation_description` 行为，本次不调整不同描述注解之间的优先级。
- 只读取方法最前面注解之前、允许隔空行的紧邻 Javadoc。没有注解时以方法行作为锚点。
- 必须找到配对的 `/**` 和 `*/`；普通块注释、不完整注释、不相邻注释返回 `nil`。
- 清洗顺序：完整结束符、开头 `/**`、行首装饰 `*`、首尾空白。不得全局删除正文中的 `*` 或 `/`。
- 正文只取第一个非空段落，续行用一个空格连接；空行结束段落。
- 块标签开始后，不再把其续行视为普通正文，避免参数说明污染 API 名称。
- 支持 `@description: 内容` 和 `@description 内容`，也支持标签当行为空、内容在后续行的情况。
- `@description` 的非空续行以空格连接，遇到下一个块标签停止；重复标签选择第一个清洗后非空的描述。
- 块标签按独立标签名识别，不把 `@descriptionExtra` 当作 `@description`。
- 忽略 `@param`、`@return`、`@author`、`@time` 和其他未知块标签及其续行。
- 没有有效正文或描述时返回 `nil`，不返回空字符串或手动填入方法名。
- 以上规则针对常规独占行的 Javadoc 和单行 `/** 内容 */`；同一行混排多个块标签不新增支持。

## Task 1: 固化当前故障

**Files:**
- Modify: `tests/restful_spring_spec.lua`
- Read: `lua/restful/providers/java/spring.lua`
- Read: `lua/restful/picker.lua`

1. 在现有测试的最终成功输出之前，新增局部测试辅助函数，生成带 Javadoc 的 `SysMenuClient` 接口及 `findByMenuType` 方法。保留泛型返回值、多行参数、`@RequestMapping` 和参数注解；测试数据不依赖业务仓库绝对路径。
2. 使用 `declaration_parser = function() return nil end` 强制 fallback，确保故障测试不依赖 Java Tree-sitter 是否安装。
3. 添加只有 `@param`、`@return` 的注释用例，断言 `endpoint.description == nil`、`endpoint.handler_name == "findByMenuType"`、`picker.display_name(endpoint) == "findByMenuType"`。
4. 添加与报告同构的 `@description:` 用例，断言描述等于预设文本、名称等于描述、路径仍为 `/findByMenuType`、HTTP 方法仍为 `ANY`。
5. 使用包含中文的描述断言字符原样保留；测试文件引入中文的理由是回归用户实际输入。
6. 执行下列命令，确认至少出现预期 assertion failure，而不是模块加载或语法错误。

```sh
nvim --headless -u NONE '+lua local ok, err = pcall(dofile, "tests/restful_spring_spec.lua"); if not ok then print(err); vim.cmd("cquit 1") end' '+qa!'
```

**Expected:** 修复前失败；具体失败为 description 或 display_name 不符合预期。必须检查退出码，不能只依赖 `+qa!`。

## Task 2: 修复注释边界处理

**Files:**
- Modify: `lua/restful/providers/java/spring.lua`，`javadoc_description`
- Modify: `tests/restful_spring_spec.lua`

1. 增加空 Javadoc、仅标签、普通多行正文、单行 Javadoc 测试，分别验证回退或正确正文。
2. 保留最前注解行定位逻辑。向上收集完整注释时记录是否找到 `/**`；遇到不属于当前注释的边界或未找到开始符时返回 `nil`。
3. 先删除完整结束符再处理装饰前缀，逐行 `vim.trim`；起止符必须匹配边界，不破坏正文中的 URL、斜杠或星号。
4. 将完整注释按源文件顺序交给内容选择逻辑；不要依靠逆序插入后的偶然排序屏蔽无效文本。
5. 增加普通 `/* ... */`、未配对结束符、其他声明隔开注释的测试，确认不会误关联。
6. 执行 Task 1 的命令。此阶段允许 `@description` 用例仍失败，但边界、正文与无描述回退用例必须通过。

**Expected:** 分隔符不再成为 description，合法正文不受损，方法名和路径不变。

## Task 3: 支持正文首段与 description 标签

**Files:**
- Modify: `lua/restful/providers/java/spring.lua`，`javadoc_description`
- Modify: `tests/restful_spring_spec.lua`

1. 添加下方测试矩阵中尚未覆盖的用例，断言最终 description 和 display_name，而不仅是 endpoint 数量。
2. 在同一个私有函数内按源顺序遍历清洗后的行，维护正文首段、当前块标签、当前 description 候选。仅使用完成当前规则所需的局部状态。
3. 正文首段遇空行后冻结；遇任何块标签后进入标签区域，其续行不得重新进入正文。
4. 精确识别 description 标签，去除可选冒号及首尾空白，收集续行，在下个块标签或注释结束时确定候选。
5. 返回非空正文首段，否则返回首个非空 description，否则返回 `nil`。继续由现有 `annotation_description(...) or javadoc_description(...)` 决定描述注解优先级。
6. 执行 Task 1 的命令，确认全部测试通过，输出 `api-query-spring-tests: ok` 且退出码为 0。

| 输入 | 预期 |
| --- | --- |
| `@description: 内容` | 内容 |
| `@description 内容` | 内容 |
| description 标签空行起始、后续有内容 | 续行内容 |
| description 多行且后接 `@return` | 合并描述，不包含返回值说明 |
| 普通正文多行 | 首段以空格连接 |
| 普通正文两段 | 仅第一段 |
| 正文与 description 同时存在 | 正文优先 |
| 参数说明存在多行续行 | 不显示参数说明 |
| 空 description、无正文 | description 为 nil，名称为方法名 |
| 首个 description 为空、第二个有内容 | 第二个内容 |
| `@descriptionExtra` | 忽略该标签 |
| `@Operation(summary = "...")` 与 Javadoc 并存 | summary 优先 |
| `@ApiOperation("...")` 与 Javadoc 并存 | ApiOperation 内容优先 |
| 正文包含 URL、斜杠或星号 | 保留正文字符 |
| 无注释 | 回退方法名 |

## Task 4: 验证解析路径和展示链路

**Files:**
- Modify: `tests/restful_spring_spec.lua`
- Read only: `lua/restful/providers/java/declarations.lua`
- Read only: `lua/restful/providers/java/fallback.lua`
- Read only: `lua/restful/model.lua`
- Read only: `lua/restful/picker.lua`

1. 将核心用例复用于强制 fallback 和默认解析路径，避免复制整套断言。
2. 显式调用 `declarations.parse(source)` 检测真实 Java parser 是否可用。可用时注入真实 parser，并在返回 nil 时直接断言失败，禁止静默退回 fallback 后声称 Tree-sitter 已验证。
3. Tree-sitter 不可用时打印明确 skip；不能将默认解析路径通过等同于 Tree-sitter 通过，不自动下载解析器。
4. 增加包含多个方法的接口用例，验证前一个方法的 Javadoc 不泄漏到后一个方法。
5. 对核心结果调用 `model.endpoint`、`picker.item_for`、`picker.format_endpoint`，确认模型描述、搜索文本和名称片段均正确，不只验证独立的 display_name 函数。
6. 保留路径、HTTP 方法、handler_name、声明行号和方法行号的断言，确保名称修复没有影响导航或请求信息。
7. 执行 Task 1 的命令，记录真实执行的 parser 模式和任何 skip。

**Expected:** 同一源码在已验证的解析模式下产生相同名称。无需加载 Snacks 即可测试格式化入口。

## Task 5: 全量验证与真实项目验收

**Files:**
- Review: `lua/restful/providers/java/spring.lua`
- Review: `tests/restful_spring_spec.lua`
- Existing commands: `Makefile`、`scripts/test.sh`

1. 运行 `make test`，检查每个测试文件的输出。当前脚本直接使用 `+luafile ... +qa!`，不能仅凭 shell 成功判断所有 assertion 成功。
2. 使用下面的严格退出码命令再执行所有测试，各测试维持独立 Neovim 进程；无需为本修复修改测试脚本。

```sh
for test_file in tests/*_spec.lua; do
  RESTFUL_TEST_FILE="$test_file" nvim --headless -u NONE '+lua local ok, err = pcall(dofile, vim.env.RESTFUL_TEST_FILE); if not ok then print(err); vim.cmd("cquit 1") end' '+qa!' || exit 1
```

3. 若已安装 StyLua，对修改的 Lua 文件运行定向检查。先确认现有格式基线，避免整文件重排；既有格式问题与新增问题分别报告。

```sh
stylua --check lua/restful/providers/java/spring.lua tests/restful_spring_spec.lua
git diff --check
git diff --stat
git diff -- lua/restful/providers/java/spring.lua tests/restful_spring_spec.lua
```

4. 在已加载新版插件的 Neovim 中进入 moss 项目，运行 `:RestfulRefresh!`，完成后运行 `:Restful findByMenuType`。仅刷新索引不会重新加载 Lua 模块，推荐重启 Neovim 后验收。
5. 确认 SysMenuClient 条目名称为“根据菜单类型和菜单的名称获取相关配置”，URL 仍为 `/findByMenuType`，可以跳转到原方法；不修改业务注释作为规避方案。
6. 确认相邻 Controller 条目的原有描述和路径不变，无描述方法仍显示方法名。
7. 若无法操作用户实际 UI，明确将该步骤标记为待手工验收，不以 headless 格式化测试替代真实 UI 验收声明。
8. 最终交付报告包含改动文件、修复规则、严格测试退出码、Tree-sitter 覆盖情况、格式工具或 UI 验收限制。未经用户要求不提交或推送。

## 完成标准

- 原始故障有可重复的失败测试，并在修复后通过。
- 正确清除 Javadoc 分隔符，不污染 description。
- 支持指定 description 格式和续行规则，正文及描述注解优先级明确。
- 无有效描述时稳定回退到方法名，picker 不含特殊字符串补丁。
- 强制 fallback 已验证；真实 Tree-sitter 已验证或明确列为环境限制。
- 全量测试使用严格退出码检查通过，修改不涉及无关重构。
- 业务 Java 文件保持不变；实际 UI 验收结果如实记录。
