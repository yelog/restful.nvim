# restful.nvim Extraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract the current `api_query` endpoint discovery and query panel from the personal Neovim configuration into a standalone `restful.nvim` plugin without regressing indexing, navigation, or request generation.

**Architecture:** Keep endpoint parsing and indexing independent from UI and request-runner plugins. Expose one public `require("restful")` facade; place Snacks picker and Kulala integration behind adapters so core tests run under `nvim --headless -u NONE`. Migrate in two phases: first build and verify the external plugin, then switch the personal configuration and remove the in-tree `api_query` implementation.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim >= 0.10, `vim.system`, ripgrep, Snacks picker, optional Kulala, headless Neovim tests, StyLua, GitHub Actions.

---

## 1. Current-State Analysis

### 1.1 Entry points and user flow

The current implementation lives at `/Users/yelog/.config/nvim/lua/api_query` and is loaded directly from `/Users/yelog/.config/nvim/init.lua:60`:

```lua
require("api_query").setup()
```

The two user keymaps are in `/Users/yelog/.config/nvim/lua/key-map.lua:219-220`:

```lua
map("n", "<D-S-i>", function() require("api_query").open() end, { desc = "Query API endpoint" })
map("n", "<leader>iq", function() require("api_query").open() end, { desc = "Query API endpoint" })
```

The runtime flow is:

```text
require("api_query").open(opts)
  -> config.get() + call-specific opts
  -> index.finder(opts)
     -> rg candidate discovery (async)
     -> scanner.scan_file()
        -> detector.for_file()
        -> provider.parse()/extract()/resolve()
        -> model.endpoint()
     -> stream endpoints to Snacks
     -> atomically commit the completed generation to per-root state
  -> picker.open()
     -> Enter: jump to handler/declaration
     -> Ctrl-O: open generated .http request buffer
     -> Ctrl-R: generate and send through Kulala
```

`setup()` also creates these commands and a write invalidation autocmd:

- `:ApiQuery [METHOD] [query]`
- `:ApiQueryRefresh[!]`
- `:ApiQueryDiagnostics`
- `:ApiQueryFrameworks`
- `BufWritePost` and `FileChangedShellPost` for Java, Python, Go, JavaScript, and TypeScript files

### 1.2 Module responsibilities

| Current file | Responsibility | Extraction decision |
| --- | --- | --- |
| `lua/api_query/init.lua` | Public facade, commands, autocmds | Rewrite as `lua/restful/init.lua`; make setup idempotent |
| `lua/api_query/config.lua` | Defaults and deep merge | Rename; validate only options needed by v1 |
| `lua/api_query/index.lua` | Root state, candidate discovery, async parsing, invalidation | Preserve behavior; isolate endpoint filtering |
| `lua/api_query/scanner.lua` | Provider orchestration and normalization | Preserve with namespace changes |
| `lua/api_query/detector.lua` | Provider selection by source evidence | Preserve; normalize provider IDs/aliases |
| `lua/api_query/model.lua` | Endpoint/parameter normalization and stable IDs | Preserve as core contract |
| `lua/api_query/graph.lua` | Mount/prefix composition | Preserve |
| `lua/api_query/constants.lua` | Static expression evaluation | Preserve |
| `lua/api_query/imports.lua` | JS import parsing | Preserve, although currently unused by the main flow |
| `lua/api_query/treesitter.lua` | String parser adapter | Preserve; Tree-sitter parser remains optional per language |
| `lua/api_query/diagnostics.lua` | Diagnostic collection | Extend with usable quickfix output |
| `lua/api_query/picker.lua` | Snacks formatting, finder bridge, navigation/actions | Move to `lua/restful/picker.lua`; treat Snacks as UI dependency |
| `lua/api_query/request.lua` | `.http` materialization and Kulala execution | Preserve pure materializer; keep Kulala optional |
| `lua/api_query/providers/**` | Eleven framework providers | Copy and namespace under `restful.providers` |

Built-in providers currently cover:

- Java: Spring MVC, JAX-RS
- Python: FastAPI, Flask, Django
- Go: `net/http`, Gin, Chi
- JavaScript/TypeScript: Express, Fastify, NestJS

### 1.3 Runtime dependencies

Required:

- Neovim APIs: `vim.fs`, `vim.system`, `vim.schedule`, `vim.defer_fn`, `vim.uv`/`vim.loop`
- `rg` for the asynchronous finder path
- Snacks picker for streaming results into the current query panel

Optional:

- Kulala for immediate request execution; without it, request generation must still open an `http` scratch buffer
- Tree-sitter Java parser; Spring falls back to its line-based declaration parser
- Nerd Font for method icons; the initial extraction will preserve icons but document this display expectation

No external Lua rock is required. The current tests run directly with `nvim --headless -u NONE`.

### 1.4 State and concurrency model

`index.lua` maintains one state object per normalized root:

```lua
{
  root = root,
  status = "idle" | "loading" | "ready" | "stale" | "error",
  generation = 0,
  files = {},
  endpoints = {},
  diagnostics = diagnostics.new(),
  updated_at = nil,
  error = nil,
  stale_files = {},
}
```

Important invariants to preserve:

- A stale asynchronous generation never overwrites a newer generation.
- Closing the picker aborts `rg`, cancels parsing, and resumes the Snacks async context exactly once.
- Parsing yields after `parse_budget_ms` to avoid blocking the UI.
- A file refresh replaces only that file's report and preserves endpoints from unchanged files.
- Duplicate endpoint IDs are emitted and committed only once.
- States for different roots never share endpoints or generations.

### 1.5 Verified baseline and known gaps

Baseline verified on 2026-09-04:

- Neovim: `0.12.4`
- ripgrep: `15.1.0`
- All 9 existing `api_query_*_spec.lua` headless tests pass
- `stylua` is not installed on the current machine
- `/Users/yelog/workspace/vi/restful.nvim` is empty and is not a Git repository

Known implementation gaps that must be handled deliberately:

- `:ApiQuery METHOD query` parses `method` and `query`, but neither currently filters endpoints or initializes the picker query.
- Picker request actions call `request.open(item)`/`request.run(item)` without forwarding `config.request`, so configured base URL and confirmation behavior are lost.
- `confirm_unsafe_methods = false` has no effect because `request.run()` always confirms non-safe methods.
- `ApiQueryFrameworks` asks `index.frameworks`, which does not exist; the command always reports no frameworks.
- `ApiQueryDiagnostics` has no useful UI because `diagnostics.open()` does not exist and `diagnostics.list()` is called without a target collection.
- `cache.persistent` and `scan.libraries` are declared but not implemented.
- Provider IDs are inconsistent (`java-spring`/`java-jaxrs` versus `spring`/`jaxrs`), with ad hoc Java alias handling.
- Python providers do not declare `id`, `languages`, or `detect`; registration currently derives an ID from the module name.
- The fallback `vim.ui.select` cannot consume an asynchronous finder and therefore cannot replace Snacks for cold indexing.
- The plugin configuration file `/Users/yelog/.config/nvim/lua/plugins/panel/api-query.lua` is only a placeholder and does not install anything.

Scope decision for v1:

- Fix command filtering, request option forwarding, unsafe confirmation configuration, framework reporting, and diagnostic display because they are already advertised behavior.
- Keep `persistent = false` and `libraries = false`; remove those inactive options from v1 defaults rather than shipping misleading configuration.
- Require Snacks for `open()` and return an actionable error if it is unavailable. Keep core indexing APIs usable without Snacks.
- Keep Kulala optional.
- Do not add an `api_query` compatibility namespace. There is one known consumer, and it will be migrated in the same change set.

## 2. Target Repository Layout

Create this structure under `/Users/yelog/workspace/vi/restful.nvim`:

```text
restful.nvim/
├── .github/workflows/ci.yml
├── .gitignore
├── .luacheckrc
├── .luarc.json
├── LICENSE
├── Makefile
├── README.md
├── doc/restful.txt
├── docs/plans/2026-09-04-restful-nvim-extraction.md
├── lua/restful/
│   ├── config.lua
│   ├── constants.lua
│   ├── detector.lua
│   ├── diagnostics.lua
│   ├── graph.lua
│   ├── imports.lua
│   ├── index.lua
│   ├── init.lua
│   ├── model.lua
│   ├── picker.lua
│   ├── request.lua
│   ├── scanner.lua
│   ├── treesitter.lua
│   └── providers/
│       ├── init.lua
│       ├── go/{chi,gin,net_http}.lua
│       ├── java/{declarations,fallback,jaxrs,spring}.lua
│       ├── node/{express,fastify,nest}.lua
│       └── python/{django,fastapi,flask}.lua
├── scripts/test.sh
├── stylua.toml
└── tests/
    ├── helpers.lua
    ├── config_spec.lua
    ├── init_spec.lua
    ├── model_spec.lua
    ├── provider_java_spec.lua
    ├── provider_python_spec.lua
    ├── provider_go_spec.lua
    ├── provider_node_spec.lua
    ├── scanner_spec.lua
    ├── index_spec.lua
    ├── index_async_spec.lua
    ├── index_incremental_spec.lua
    ├── picker_spec.lua
    ├── request_spec.lua
    └── diagnostics_spec.lua
```

Public API for v1:

```lua
local restful = require("restful")

restful.setup(opts)
restful.open(opts)
restful.refresh(opts)
restful.diagnostics(opts)
restful.frameworks(opts)
restful.register_provider(provider)
```

Supported call-specific options:

```lua
require("restful").open({
  root = vim.fn.getcwd(),
  method = "GET",
  query = "users",
  force = false,
})
```

Configuration shape:

```lua
require("restful").setup({
  cache = { debounce_ms = 400 },
  scan = {
    exclude = { ".git", "node_modules", "vendor", "target", "build", "dist" },
    parse_budget_ms = 6,
  },
  providers = {},
  request = {
    base_url_variable = "API_BASE_URL",
    fallback_base_url = "http://localhost:8080",
    confirm_unsafe_methods = true,
  },
  picker = {
    title = "RESTful",
    keys = { open = "<c-o>", run = "<c-r>" },
  },
})
```

Commands for v1:

```text
:Restful [METHOD] [query]
:RestfulRefresh[!]
:RestfulDiagnostics
:RestfulFrameworks
```

## 3. Implementation Tasks

### Task 1: Initialize the standalone repository and test harness

**Files:**

- Create: `/Users/yelog/workspace/vi/restful.nvim/.gitignore`
- Create: `/Users/yelog/workspace/vi/restful.nvim/.luarc.json`
- Create: `/Users/yelog/workspace/vi/restful.nvim/.luacheckrc`
- Create: `/Users/yelog/workspace/vi/restful.nvim/stylua.toml`
- Create: `/Users/yelog/workspace/vi/restful.nvim/scripts/test.sh`
- Create: `/Users/yelog/workspace/vi/restful.nvim/Makefile`
- Create: `/Users/yelog/workspace/vi/restful.nvim/tests/helpers.lua`

**Step 1: Initialize Git**

Run:

```bash
git init
```

Expected: an empty repository exists at `/Users/yelog/workspace/vi/restful.nvim/.git`.

**Step 2: Add formatting and Lua-language-server configuration**

Use the existing style as the source of truth:

```toml
indent_type = "Spaces"
indent_width = 2
column_width = 120
```

Set `.luarc.json` to LuaJIT, include the `vim` global, and add `lua/?.lua` plus `lua/?/init.lua` to the workspace library/path.

**Step 3: Add one deterministic test runner**

Create `scripts/test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for test_file in "$repo_root"/tests/*_spec.lua; do
  nvim --headless -u NONE "+luafile $test_file" "+qa!"
done
```

Create a `Makefile` with `test`, `format`, and `format-check` targets. `test` invokes the script; format targets invoke `stylua lua tests`.

**Step 4: Add shared test path setup**

Create `tests/helpers.lua` that derives the repository root from `debug.getinfo`, prepends plugin Lua paths once, resets named modules from `package.loaded`, and provides temporary-file cleanup helpers. Do not introduce Plenary or Busted.

**Step 5: Verify the empty harness fails for the right reason**

Run:

```bash
make test
```

Expected: no specs exist yet, so the shell glob behavior must be handled explicitly. Add `shopt -s nullglob`, collect files, and fail with `no test files found` until Task 2 adds the first spec.

**Step 6: Commit**

```bash
git add .gitignore .luarc.json .luacheckrc stylua.toml scripts/test.sh Makefile tests/helpers.lua docs/plans/2026-09-04-restful-nvim-extraction.md
git commit -m "chore: initialize restful.nvim plugin"
```

### Task 2: Establish configuration and endpoint model contracts

**Files:**

- Create: `lua/restful/config.lua`
- Create: `lua/restful/model.lua`
- Create: `lua/restful/constants.lua`
- Create: `lua/restful/graph.lua`
- Create: `lua/restful/imports.lua`
- Create: `tests/config_spec.lua`
- Create: `tests/model_spec.lua`

**Step 1: Write failing configuration tests**

Cover:

- Defaults match the v1 configuration shown above.
- `setup()` does not mutate `defaults`.
- A second `setup()` starts from defaults rather than retaining keys from the first call.
- Nested user options merge without deleting sibling defaults.
- `get()` lazily initializes defaults.

Representative assertion:

```lua
local config = require("restful.config")
local first = config.setup({ request = { fallback_base_url = "http://localhost:3000" } })
assert(first.request.base_url_variable == "API_BASE_URL")
assert(first.request.fallback_base_url == "http://localhost:3000")

local second = config.setup()
assert(second.request.fallback_base_url == "http://localhost:8080")
```

**Step 2: Run tests and verify failure**

Run:

```bash
nvim --headless -u NONE "+luafile tests/config_spec.lua" "+qa!"
```

Expected: FAIL because `restful.config` does not exist.

**Step 3: Implement configuration**

Port `/Users/yelog/.config/nvim/lua/api_query/config.lua`, rename the namespace, remove inactive `cache.persistent` and `scan.libraries`, add `scan.parse_budget_ms`, and add picker key defaults. Use `vim.tbl_deep_extend("force", ...)` rather than maintaining a custom recursive merge.

**Step 4: Write and run failing model tests**

Port assertions from `/Users/yelog/.config/nvim/tests/api_query_model_spec.lua`. Add tests for:

- `CONNECT` is either consistently supported by both model and request materialization, or consistently rejected by both. The preferred v1 behavior is to support it.
- Stable IDs distinguish two handlers with the same framework/method/path when their source locations differ. Include normalized declaration file and line in `stable_id`; otherwise monorepos can collapse legitimate duplicate routes.
- Unknown parameter locations remain representable.

Run:

```bash
nvim --headless -u NONE "+luafile tests/model_spec.lua" "+qa!"
```

Expected: FAIL because `restful.model` does not exist.

**Step 5: Port pure core modules**

Copy behavior from:

- `/Users/yelog/.config/nvim/lua/api_query/model.lua`
- `/Users/yelog/.config/nvim/lua/api_query/constants.lua`
- `/Users/yelog/.config/nvim/lua/api_query/graph.lua`
- `/Users/yelog/.config/nvim/lua/api_query/imports.lua`

Change only the stable ID collision issue and namespace references. Avoid provider-specific logic in these files.

**Step 6: Run focused tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/config_spec.lua" "+qa!"
nvim --headless -u NONE "+luafile tests/model_spec.lua" "+qa!"
```

Expected: both PASS.

**Step 7: Commit**

```bash
git add lua/restful/config.lua lua/restful/model.lua lua/restful/constants.lua lua/restful/graph.lua lua/restful/imports.lua tests/config_spec.lua tests/model_spec.lua
git commit -m "feat: add endpoint model and configuration"
```

### Task 3: Add provider registry, detector, scanner, and diagnostics collection

**Files:**

- Create: `lua/restful/providers/init.lua`
- Create: `lua/restful/detector.lua`
- Create: `lua/restful/scanner.lua`
- Create: `lua/restful/diagnostics.lua`
- Create: `lua/restful/treesitter.lua`
- Create: `tests/scanner_spec.lua`
- Create: `tests/diagnostics_spec.lua`

**Step 1: Write failing registry and scanner tests**

Create a fake provider and verify the public provider contract:

```lua
local providers = require("restful.providers")
providers._reset()
providers.register({
  id = "fixture",
  aliases = { "fixture-alias" },
  languages = { "lua" },
  detect = function() return { language = "lua", framework = "fixture" } end,
  parse = function(_, context)
    return {
      endpoints = {
        { methods = { "GET" }, path = "/fixture", handler = { file = context.file, line = 1 } },
      },
    }
  end,
})
```

Assert duplicate IDs fail clearly, aliases resolve through `get()`, provider parse failures become diagnostics instead of aborting scanning, and endpoint locations are normalized.

**Step 2: Run tests and verify failure**

Run:

```bash
nvim --headless -u NONE "+luafile tests/scanner_spec.lua" "+qa!"
```

Expected: FAIL because the registry/scanner modules do not exist.

**Step 3: Implement the registry contract**

Each provider must expose:

```lua
---@class RestfulProvider
---@field id string
---@field aliases? string[]
---@field languages string[]
---@field detect? fun(context: table): table?
---@field parse? fun(text: string, context: table): table
---@field extract? fun(context: table, file: table|string, tree?: table): table
---@field resolve? fun(context: table, fragments: table[], graph: table): table[]
```

Implement `register`, `get`, `list`, `load`, and test-only `_reset`. Built-ins load lazily from an explicit module list. Normalize Spring and JAX-RS IDs to `spring` and `jaxrs`; if aliases are retained internally, they should only ease provider lookup, not appear in endpoint output.

**Step 4: Port detector/scanner/Tree-sitter adapter**

Port current behavior with `restful.*` requires. Keep provider exceptions isolated with `pcall`. Make `scanner.scan_file()` return this stable report shape:

```lua
{
  path = path,
  endpoints = {},
  fragments = {},
  diagnostics = diagnostics.new(),
  frameworks = {},
}
```

Record every successfully selected provider ID in `frameworks`; the index will aggregate this for `:RestfulFrameworks`.

**Step 5: Implement diagnostics output data**

Keep `new`, `add`, `merge`, and `list`. Add `to_qflist(target)` that maps diagnostics to `{ filename, lnum, col, text, type }`; do not open UI in this core module.

**Step 6: Run focused tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/scanner_spec.lua" "+qa!"
nvim --headless -u NONE "+luafile tests/diagnostics_spec.lua" "+qa!"
```

Expected: both PASS.

**Step 7: Commit**

```bash
git add lua/restful/providers/init.lua lua/restful/detector.lua lua/restful/scanner.lua lua/restful/diagnostics.lua lua/restful/treesitter.lua tests/scanner_spec.lua tests/diagnostics_spec.lua
git commit -m "feat: add provider scanning pipeline"
```

### Task 4: Port Java providers

**Files:**

- Create: `lua/restful/providers/java/declarations.lua`
- Create: `lua/restful/providers/java/fallback.lua`
- Create: `lua/restful/providers/java/spring.lua`
- Create: `lua/restful/providers/java/jaxrs.lua`
- Create: `tests/provider_java_spec.lua`

**Step 1: Write failing Java provider tests**

Port all cases from:

- `/Users/yelog/.config/nvim/tests/api_query_spring_spec.lua`
- The Spring fixture in `/Users/yelog/.config/nvim/tests/api_query_provider_spec.lua`

Add JAX-RS cases for class `@Path`, method `@GET`/`@POST`, method `@Path`, and `@PathParam`/`@QueryParam`.

**Step 2: Run and verify failure**

Run:

```bash
nvim --headless -u NONE "+luafile tests/provider_java_spec.lua" "+qa!"
```

Expected: FAIL because Java providers do not exist.

**Step 3: Port implementation**

Copy the four current Java modules, replace `api_query.*` requires with `restful.*`, and set provider metadata consistently:

```lua
local M = {
  id = "spring", -- or "jaxrs"
  languages = { "java" },
  framework = "spring", -- or "jaxrs"
}
```

Preserve Tree-sitter-first Spring parsing and the fallback parser. Do not rewrite annotation parsing during extraction.

**Step 4: Run the focused test**

Expected: PASS both with the Java parser available and when the test injects an unavailable parser.

**Step 5: Commit**

```bash
git add lua/restful/providers/java tests/provider_java_spec.lua
git commit -m "feat: add Java endpoint providers"
```

### Task 5: Port Python providers

**Files:**

- Create: `lua/restful/providers/python/fastapi.lua`
- Create: `lua/restful/providers/python/flask.lua`
- Create: `lua/restful/providers/python/django.lua`
- Create: `tests/provider_python_spec.lua`

**Step 1: Write failing provider tests**

Cover FastAPI router prefixes and `include_router`, Flask blueprint prefixes and `register_blueprint`, and Django `path`/`re_path` plus `include` fragments. Assert file/line locations survive the scanner, not merely direct provider calls.

**Step 2: Add provider metadata before registration**

Each module must define `id`, `languages`, `framework`, and `detect`. Detection must use source evidence as well as optional `package_json`; scanning a standalone source file must not require reading project manifests.

**Step 3: Port parsers without broadening syntax support**

Copy current parsing behavior, then make only contract-level corrections needed by scanner normalization. Do not attempt cross-file Django include resolution in v1.

**Step 4: Run tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/provider_python_spec.lua" "+qa!"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add lua/restful/providers/python tests/provider_python_spec.lua
git commit -m "feat: add Python endpoint providers"
```

### Task 6: Port Go providers

**Files:**

- Create: `lua/restful/providers/go/gin.lua`
- Create: `lua/restful/providers/go/chi.lua`
- Create: `lua/restful/providers/go/net_http.lua`
- Create: `tests/provider_go_spec.lua`

**Step 1: Write failing tests**

Cover Gin group prefixes, Chi route/mount prefixes, and Go 1.22 `net/http` patterns such as `"GET /users/{id}"`. Assert method normalization and handler source locations.

**Step 2: Port providers**

Retain their current line-based extraction and provider metadata. Keep route composition local to each provider; do not introduce a cross-file Go symbol graph in v1.

**Step 3: Run tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/provider_go_spec.lua" "+qa!"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add lua/restful/providers/go tests/provider_go_spec.lua
git commit -m "feat: add Go endpoint providers"
```

### Task 7: Port JavaScript and TypeScript providers

**Files:**

- Create: `lua/restful/providers/node/express.lua`
- Create: `lua/restful/providers/node/fastify.lua`
- Create: `lua/restful/providers/node/nest.lua`
- Create: `tests/provider_node_spec.lua`

**Step 1: Write failing tests**

Cover Express `Router`, `app.use`, and chained `route`; Fastify shorthand/`route`/`register`; NestJS controller prefixes, method decorators, and parameter decorators.

**Step 2: Port implementations**

Add consistent metadata and source-evidence detection. Preserve current parser limitations; do not add JS/TS AST dependencies in v1.

**Step 3: Run tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/provider_node_spec.lua" "+qa!"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add lua/restful/providers/node tests/provider_node_spec.lua
git commit -m "feat: add Node endpoint providers"
```

### Task 8: Port asynchronous and incremental indexing

**Files:**

- Create: `lua/restful/index.lua`
- Create: `tests/index_spec.lua`
- Create: `tests/index_async_spec.lua`
- Create: `tests/index_incremental_spec.lua`

**Step 1: Port state and candidate-discovery tests first**

Merge coverage from:

- `/Users/yelog/.config/nvim/tests/api_query_index_spec.lua`
- `/Users/yelog/.config/nvim/tests/api_query_index_state_spec.lua`
- `/Users/yelog/.config/nvim/tests/api_query_async_spec.lua`
- `/Users/yelog/.config/nvim/tests/api_query_incremental_spec.lua`

Add explicit tests for deleted files: if `refresh_file()` cannot read a previously indexed path because it was deleted, remove its old report without adding a permanent noisy diagnostic.

**Step 2: Add method filtering tests**

Introduce a small local predicate in `index.lua` or a private helper, not a new public module:

```lua
local function matches(endpoint, opts)
  if not opts.method or opts.method == "" then return true end
  local wanted = opts.method:upper()
  return vim.tbl_contains(endpoint.methods or {}, wanted)
end
```

Verify filtering applies identically to cached arrays and asynchronously streamed endpoints. Free-text `query` remains a picker concern.

**Step 3: Run tests and verify failure**

Run:

```bash
nvim --headless -u NONE "+luafile tests/index_spec.lua" "+qa!"
nvim --headless -u NONE "+luafile tests/index_async_spec.lua" "+qa!"
nvim --headless -u NONE "+luafile tests/index_incremental_spec.lua" "+qa!"
```

Expected: FAIL because `restful.index` does not exist.

**Step 4: Port `index.lua` with minimal corrections**

Preserve:

- `rg --files-with-matches` candidate narrowing
- Exclude globs
- `vim.system` asynchronous discovery
- cancellation and late-callback suppression
- parse time budgeting
- generation-based atomic commits
- per-root in-memory state
- debounced file invalidation

Correct:

- Read parse budget from `opts.scan.parse_budget_ms` after facade option normalization.
- Aggregate `state.frameworks[provider_id] = endpoint_count` during rebuild/commit.
- Apply method filtering only at query/stream time; never delete non-matching endpoints from cached state.
- Expose `M.frameworks(root)` as a copied table so callers cannot mutate index state.
- Keep synchronous `scan_root()` for tests and programmatic use, but make `open()` use the asynchronous finder.

**Step 5: Run focused and full tests**

Run:

```bash
make test
```

Expected: all current specs PASS; cancellation tests do not hang.

**Step 6: Commit**

```bash
git add lua/restful/index.lua tests/index_spec.lua tests/index_async_spec.lua tests/index_incremental_spec.lua
git commit -m "feat: add asynchronous endpoint index"
```

### Task 9: Port request materialization and Kulala adapter

**Files:**

- Create: `lua/restful/request.lua`
- Create: `tests/request_spec.lua`

**Step 1: Write failing pure materialization tests**

Port `/Users/yelog/.config/nvim/tests/api_query_request_spec.lua` and add:

- Path, query, header, JSON body, repeated query values, and URL encoding
- Base URL precedence
- Secret/unresolved placeholders never materialize secret values
- Invalid methods have deterministic behavior
- `confirm_unsafe_methods = false` sends without prompting
- `confirm_unsafe_methods = true` cancels when confirmation is rejected
- Missing Kulala opens a draft instead of failing

Inject confirmation and runner functions through `context` in tests; do not depend on installed Kulala.

**Step 2: Run and verify failure**

Run:

```bash
nvim --headless -u NONE "+luafile tests/request_spec.lua" "+qa!"
```

Expected: FAIL because `restful.request` does not exist.

**Step 3: Port the pure materializer**

Copy current encoding, grouping, placeholder, body, and URL logic. Keep `materialize()` free of editor state and external modules.

**Step 4: Correct request execution configuration**

Unsafe confirmation logic must be:

```lua
if not SAFE_METHODS[method] and context.confirm_unsafe_methods ~= false then
  local confirm = context.confirm or default_confirm
  if not confirm or not confirm("Send " .. method .. " request?", { kind = "warning" }) then
    return nil, "cancelled"
  end
end
```

Allow `context.runner` injection; default to `require("kulala").run`. Set the generated scratch buffer's `filetype` to `http`, `bufhidden` to `wipe`, and a descriptive buffer name such as `restful://METHOD/path` when possible.

**Step 5: Run tests**

Expected: PASS without loading the user's Neovim configuration.

**Step 6: Commit**

```bash
git add lua/restful/request.lua tests/request_spec.lua
git commit -m "feat: add HTTP request generation"
```

### Task 10: Build the Snacks query panel adapter

**Files:**

- Create: `lua/restful/picker.lua`
- Create: `tests/picker_spec.lua`

**Step 1: Write failing picker contract tests**

Port `/Users/yelog/.config/nvim/tests/api_query_picker_async_spec.lua` and picker assertions from `api_query_provider_spec.lua`. Stub `_G.Snacks` and assert:

- Cold sources remain asynchronous and stream normalized picker items.
- Ready arrays become `items` immediately.
- `show_delay = 0` and `show_empty = true` remain set.
- `opts.query` becomes the Snacks picker initial `pattern`.
- `opts.picker.title` and key overrides are honored.
- Enter closes and jumps to source.
- Open/run actions forward the merged `opts.request` table.
- Missing Snacks returns `nil, "Snacks picker is required"` and notifies once.
- Jumping uses `vim.fn.fnameescape` and sets the expected line/column.

**Step 2: Run and verify failure**

Run:

```bash
nvim --headless -u NONE "+luafile tests/picker_spec.lua" "+qa!"
```

Expected: FAIL because `restful.picker` does not exist.

**Step 3: Port formatting and finder bridge**

Keep method icon/highlight formatting and right-aligned source filenames. Rename notification prefixes to `restful:` and use title `RESTful`.

Use the current Snacks custom picker API:

```lua
local picker_opts = {
  title = opts.picker.title,
  pattern = opts.query,
  show_delay = 0,
  show_empty = true,
  format = format_endpoint,
  finder = wrapped_finder,
  actions = actions,
  win = { input = { keys = keys } },
}
```

Do not add Telescope/fzf-lua adapters in v1. `vim.ui.select` may remain only for already-materialized arrays, but document that the normal query panel requires Snacks.

**Step 4: Forward request options**

Change action closure construction so both actions receive:

```lua
request[action](picker:selected(), opts.request)
```

This is required for base URL and unsafe-method configuration to work.

**Step 5: Run tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/picker_spec.lua" "+qa!"
```

Expected: PASS.

**Step 6: Commit**

```bash
git add lua/restful/picker.lua tests/picker_spec.lua
git commit -m "feat: add Snacks endpoint picker"
```

### Task 11: Add public facade, commands, autocmd lifecycle, and diagnostics UI

**Files:**

- Create: `lua/restful/init.lua`
- Create: `tests/init_spec.lua`

**Step 1: Write failing facade tests**

Stub `restful.index` and `restful.picker` to verify:

- `setup()` can be called twice without duplicate commands/autocmds.
- `:Restful GET users` calls `open({ method = "GET", query = "users" })`.
- Invalid first tokens are treated as free-text query rather than silently becoming a method filter.
- `open()` passes the full merged config to index and picker.
- `refresh(true)` forwards `force = true`.
- `register_provider()` delegates to the registry.
- `frameworks()` reports deterministic sorted `name count` lines.
- `diagnostics()` populates and opens a quickfix list for the current root.

**Step 2: Define command parsing**

Recognize only this method set as the optional first argument:

```lua
GET POST PUT PATCH DELETE HEAD OPTIONS TRACE CONNECT ANY ALL
```

Examples:

```text
:Restful GET users  -> method=GET, query=users
:Restful users      -> query=users
:Restful            -> no prefilter
```

**Step 3: Implement idempotent setup**

Use one augroup named `RestfulIndex` with `clear = true`. Recreating user commands with `force = true` is preferable to `exists()` checks because it makes re-sourcing deterministic.

Autocmd callback:

```lua
callback = function(args)
  require("restful.index").invalidate(args.file, config.get())
end
```

**Step 4: Normalize option flow once**

`open()` must merge configuration and call-specific options once, then pass the same option object through indexing and UI:

```lua
local opts = vim.tbl_deep_extend("force", {}, config.get(), call_opts or {})
return picker.open(index.finder(opts), opts)
```

Avoid the current `opts.picker or opts` truncation that loses request options.

**Step 5: Implement advertised commands**

- `RestfulDiagnostics`: use `diagnostics.to_qflist(index.state(root).diagnostics)`, `setqflist`, then `copen` only when entries exist.
- `RestfulFrameworks`: use `index.frameworks(root)`, sort IDs, and include endpoint counts.
- `RestfulRefresh!`: force a new generation even if state is ready.

**Step 6: Run tests**

Run:

```bash
nvim --headless -u NONE "+luafile tests/init_spec.lua" "+qa!"
make test
```

Expected: all tests PASS.

**Step 7: Commit**

```bash
git add lua/restful/init.lua tests/init_spec.lua
git commit -m "feat: expose restful.nvim commands and API"
```

### Task 12: Add plugin documentation, license, and CI

**Files:**

- Create: `README.md`
- Create: `doc/restful.txt`
- Create: `LICENSE`
- Create: `.github/workflows/ci.yml`

**Step 1: Document installation and dependencies**

Include lazy.nvim installation:

```lua
{
  "yelog/restful.nvim",
  dependencies = {
    "folke/snacks.nvim",
    { "mistweaverco/kulala.nvim", ft = { "http", "rest" }, optional = true },
  },
  opts = {},
  keys = {
    { "<leader>iq", function() require("restful").open() end, desc = "Query API endpoint" },
  },
}
```

For local development, document lazy.nvim's `dev = true` form and the expected parent path `~/workspace/vi`.

**Step 2: Document behavior and limitations**

README sections:

- Supported frameworks
- Requirements and optional dependencies
- Setup and defaults
- Commands and picker keymaps
- Public API and custom provider contract
- Request safety behavior
- Current parsing limitations: mostly file-local/static, no runtime route introspection, no cross-file composition guarantee
- Troubleshooting for missing `rg`, Snacks, Kulala, and language parsers

**Step 3: Add Vim help**

Create tags for `*restful.nvim*`, `*restful-setup*`, `*restful-commands*`, `*restful-provider*`, and `*restful-api*`. Run:

```bash
nvim --headless -u NONE "+helptags doc" "+qa!"
```

Expected: `doc/tags` is generated. Decide once whether to commit it; for a conventional Neovim plugin, commit it only if repository policy explicitly wants generated tags. Otherwise add `doc/tags` to `.gitignore`.

**Step 4: Add CI**

GitHub Actions should:

- Run on Ubuntu
- Install stable Neovim and ripgrep
- Install StyLua
- Run `make format-check`
- Run `make test`

No checkout of Snacks or Kulala is needed because adapter tests stub them.

**Step 5: Add a license**

Use MIT only after confirming the desired copyright holder/year. This is the one implementation detail requiring user confirmation before publishing.

**Step 6: Verify docs and CI commands locally**

Run:

```bash
make test
nvim --headless -u NONE "+helptags doc" "+qa!"
```

Expected: tests PASS and help tags generate without errors. `make format-check` remains blocked locally until StyLua is installed; CI must still enforce it.

**Step 7: Commit**

```bash
git add README.md doc .github/workflows/ci.yml LICENSE .gitignore
git commit -m "docs: document restful.nvim"
```

### Task 13: Dogfood the plugin from the personal Neovim configuration

**Files:**

- Modify: `/Users/yelog/.config/nvim/lua/plugins/panel/api-query.lua`
- Modify: `/Users/yelog/.config/nvim/init.lua:60`
- Modify: `/Users/yelog/.config/nvim/lua/key-map.lua:219-220`

**Step 1: Add the local lazy.nvim plugin spec**

Replace the placeholder file with:

```lua
return {
  "yelog/restful.nvim",
  dev = true,
  dependencies = {
    "folke/snacks.nvim",
    "mistweaverco/kulala.nvim",
  },
  opts = {},
}
```

The existing lazy.nvim `dev.path = "~/workspace/vi"` resolves this to `/Users/yelog/workspace/vi/restful.nvim`.

**Step 2: Remove direct in-tree setup**

Delete only this line from `init.lua`:

```lua
require("api_query").setup()
```

Lazy's `opts = {}` will call `require("restful").setup({})`.

**Step 3: Switch keymaps**

Update both mappings to:

```lua
map("n", "<D-S-i>", function() require("restful").open() end, { desc = "Query API endpoint" })
map("n", "<leader>iq", function() require("restful").open() end, { desc = "Query API endpoint" })
```

**Step 4: Run a clean startup smoke test**

Run:

```bash
nvim --headless "+lua assert(package.loaded.restful or pcall(require, 'restful'))" "+qa!"
```

Expected: exit code 0 and no startup error.

**Step 5: Perform manual panel acceptance tests**

From representative projects, verify:

1. Open a Spring project and run `:Restful`; results stream without freezing.
2. Type a name/path fragment; filtering uses only display name and path.
3. Run `:Restful GET users`; only GET endpoints appear and the picker starts with `users`.
4. Press Enter; Neovim jumps to the handler line.
5. Press Ctrl-O; an `http` scratch buffer opens with configured base URL placeholders.
6. Press Ctrl-R on GET; Kulala runs it.
7. Press Ctrl-R on POST; confirmation appears when enabled and does not appear when disabled.
8. Save a controller after changing a route; the endpoint updates after debounce without losing routes from other files.
9. Close the picker during cold indexing; the process aborts without an error or later state overwrite.
10. Run `:RestfulFrameworks` and `:RestfulDiagnostics`; both report current-root data.

Repeat basic discovery for one Python, Go, and Node fixture or project.

**Step 6: Commit only consumer configuration changes**

From `/Users/yelog/.config`:

```bash
git add nvim/lua/plugins/panel/api-query.lua nvim/init.lua nvim/lua/key-map.lua
git commit -m "refactor(nvim): use restful.nvim plugin"
```

Do not combine the plugin repository and configuration repository in one commit.

### Task 14: Remove the old in-tree implementation after dogfooding

**Files:**

- Delete: `/Users/yelog/.config/nvim/lua/api_query/**`
- Delete: `/Users/yelog/.config/nvim/tests/api_query_*_spec.lua`
- Optionally rename: `/Users/yelog/.config/nvim/lua/plugins/panel/api-query.lua` to `restful.lua`

**Step 1: Search for remaining consumers**

Run from `/Users/yelog/.config`:

```bash
rg -n 'api_query|ApiQuery' nvim
```

Expected before deletion: only the old implementation/tests and possibly the plugin spec filename/comment remain. Do not delete until no unknown consumer appears.

**Step 2: Remove duplicate implementation and tests**

Delete the old module directory and its migrated tests. Rename the lazy spec file to `restful.lua` for discoverability.

**Step 3: Verify no old namespace remains**

Run:

```bash
rg -n 'api_query|ApiQuery' nvim
```

Expected: no matches.

**Step 4: Run both repositories' tests**

Run plugin tests:

```bash
make test
```

Run configuration tests:

```bash
for test_file in nvim/tests/*_spec.lua; do nvim --headless -u NONE "+luafile ${test_file}" "+qa!" || exit 1; done
```

Expected: both suites PASS.

**Step 5: Run final startup verification**

Run:

```bash
nvim --headless "+checkhealth restful" "+qa!"
```

If Task 15's health module is deferred, use the clean startup smoke command from Task 13 instead.

**Step 6: Commit cleanup**

From `/Users/yelog/.config`:

```bash
git add -A nvim/lua/api_query nvim/tests nvim/lua/plugins/panel
git commit -m "chore(nvim): remove in-tree API query panel"
```

Before committing, inspect `git status`, `git diff`, and `git log --oneline -10`, and stage only these intended files.

### Task 15: Add health checks before the first public release

**Files:**

- Create: `lua/restful/health.lua`
- Create: `tests/health_spec.lua`
- Modify: `README.md`
- Modify: `doc/restful.txt`

**Step 1: Write health-report tests with a stubbed `vim.health`**

Verify checks report:

- Neovim version support
- `rg` availability
- Snacks picker availability
- Kulala as optional, not an error
- Built-in provider count

**Step 2: Implement `require("restful.health").check()`**

Use `vim.health.start`, `ok`, `warn`, and `error`. Never load Snacks UI or start indexing during a health check.

**Step 3: Run tests and manual health check**

Run:

```bash
nvim --headless -u NONE "+luafile tests/health_spec.lua" "+qa!"
nvim --headless "+checkhealth restful" "+qa!"
```

Expected: the test passes; the local check reports Neovim and ripgrep as healthy, Snacks according to the configured runtime, and Kulala as optional.

**Step 4: Commit**

```bash
git add lua/restful/health.lua tests/health_spec.lua README.md doc/restful.txt
git commit -m "feat: add plugin health checks"
```

## 4. Verification Matrix

| Area | Automated verification | Manual verification |
| --- | --- | --- |
| Model | normalization, IDs, sorting, duplicate parameters | none |
| Providers | framework fixtures and source locations | test real projects for each language |
| Discovery | excludes, candidate narrowing, missing/deleted files | large repository latency |
| Async index | streaming, cancellation, generations, yielding | close picker during scan |
| Incremental index | one-file replacement and aggregation | edit/save a route |
| Picker | async bridge, formatting, actions, query prefill | visual alignment and key feel |
| Requests | materialization, placeholders, safety, missing Kulala | actual GET and confirmed POST |
| Commands | parsing, bang forwarding, diagnostics/frameworks | command completion and messages |
| Packaging | clean runtimepath load and CI | install through lazy.nvim dev mode |

Release acceptance criteria:

- `make test` passes under `nvim --headless -u NONE`.
- CI format check passes with no generated diff.
- No `api_query`/`ApiQuery` reference remains in the personal Neovim configuration after cleanup.
- The query panel streams results on a cold index and opens immediately.
- Closing the panel cancels active work without hanging.
- Cached and streamed method filters return the same endpoint set.
- Request options reach both draft and run actions.
- Unsafe methods follow `confirm_unsafe_methods` exactly.
- Missing Kulala still produces a usable request draft.
- Missing Snacks produces a clear error while core indexing remains callable.
- `:RestfulFrameworks`, `:RestfulDiagnostics`, and `:checkhealth restful` return meaningful output.
- README documents all required and optional dependencies and current parser limitations.

## 5. Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Namespace rewrite misses an internal require | plugin fails at runtime | `rg -n 'api_query' lua tests` must return no matches before migration |
| Snacks finder API changes | cold indexing does not stream/cancel | pin behavior with stub tests and document tested Snacks API; keep adapter isolated |
| Stable ID change invalidates in-memory cache | first query rescans | acceptable because cache is process-local and persistence is not implemented |
| Regex providers over-report routes | noisy results | preserve current behavior first; add framework fixtures before parser improvements |
| Root defaults to current working directory | wrong project indexed in multi-root sessions | keep explicit `open({ root = ... })` API; defer automatic LSP root selection until real usage demands it |
| Empty target repository has no release metadata | cannot publish safely | add license, README, health check, CI before tagging |
| Local StyLua is absent | formatting cannot be verified locally | install StyLua before final release or rely on CI, but do not claim local format verification |
| Removing old code too early | user loses working panel | dogfood external plugin first; make cleanup a separate commit |

## 6. Explicitly Deferred Work

Do not include these in the extraction unless a failing acceptance test proves they are required:

- Persistent on-disk endpoint cache
- Scanning dependencies, vendor directories, JARs, or installed packages
- Telescope/fzf-lua picker adapters
- Built-in HTTP transport or response UI replacing Kulala
- Runtime endpoint introspection from running applications
- Cross-file symbol resolution for router mounts/includes
- Full AST parsers for every supported language/framework
- Automatic monorepo/LSP root selection
- An `api_query` backward-compatibility namespace
- Plugin manager support beyond standard runtimepath installation examples

These are post-v1 enhancements and should be tracked separately after the standalone plugin has a stable behavioral baseline.
