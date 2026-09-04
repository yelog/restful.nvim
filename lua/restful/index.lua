local scanner = require("restful.scanner")
local model = require("restful.model")
local diagnostics = require("restful.diagnostics")
local M = {}
local roots = {}

local function normalize_root(root)
  root = vim.fs.normalize(vim.fn.fnamemodify(root or vim.fn.getcwd(), ":p"))
  return root:gsub("/$", "")
end

local function has_endpoints(state) return #state.endpoints > 0 end

local function new_state(root)
  return {
    root = root,
    status = "idle",
    generation = 0,
    files = {},
    endpoints = {},
    diagnostics = diagnostics.new(),
    frameworks = {},
    updated_at = nil,
    error = nil,
    stale_files = {},
  }
end

function M.state(root)
  root = normalize_root(root)
  roots[root] = roots[root] or new_state(root)
  return roots[root]
end

function M._reset()
  for _, state in pairs(roots) do
    if state.timer then state.timer:stop(); state.timer:close() end
  end
  roots = {}
end

function M._begin_generation(state)
  state.generation = state.generation + 1
  state.status = "loading"
  state.error = nil
  return state.generation
end

function M._commit(state, generation, working)
  if state.generation ~= generation then return false end
  table.sort(working.endpoints, model.compare)
  state.files = working.files
  state.endpoints = working.endpoints
  state.diagnostics = working.diagnostics
  state.frameworks = working.frameworks or {}
  state.status = "ready"
  state.updated_at = (vim.uv or vim.loop).now()
  state.error = nil
  state.stale_files = {}
  return true
end

local source_globs = { "*.java", "*.py", "*.go", "*.js", "*.jsx", "*.ts", "*.tsx" }
local candidate_pattern = table.concat({
  "@(RestController|Controller|RequestMapping|GetMapping|PostMapping|PutMapping|PatchMapping|DeleteMapping|Path|GET|POST|PUT|PATCH|DELETE)",
  "APIRouter|FastAPI|Blueprint|Flask|urlpatterns",
  "gin-gonic/gin|gin\\.Default|gin\\.New|go-chi/chi|chi\\.NewRouter|http\\.Handle",
  "express|fastify|@nestjs/",
}, "|")

local function fallback_files(root, opts, out, prefix)
  opts, out, prefix = opts or {}, out or {}, prefix or root
  local handle = vim.loop.fs_scandir(prefix); if not handle then return out end
  while true do
    local name, kind = vim.loop.fs_scandir_next(handle); if not name then break end
    local path = prefix .. "/" .. name
    local excluded = false; for _, part in ipairs(opts.exclude or { ".git", "node_modules", "vendor", "target", "build", "dist" }) do if name == part then excluded = true end end
    if not excluded then
      if kind == "directory" then
        fallback_files(root, opts, out, path)
      elseif vim.tbl_contains(source_globs, "*." .. (name:match("%.([^.]*)$") or "")) then
        out[#out + 1] = path
      end
    end
  end
  return out
end

local function candidate_files(root, opts)
  if vim.fn.executable("rg") ~= 1 then return fallback_files(root, opts) end
  local command = { "rg", "--files-with-matches", "--no-messages", "--hidden" }
  for _, glob in ipairs(source_globs) do vim.list_extend(command, { "--glob", glob }) end
  for _, part in ipairs(opts.exclude or { ".git", "node_modules", "vendor", "target", "build", "dist" }) do
    vim.list_extend(command, { "--glob", "!" .. part .. "/**", "--glob", "!**/" .. part .. "/**" })
  end
  vim.list_extend(command, { candidate_pattern, "." })
  local result = vim.system(command, { text = true, cwd = root }):wait()
  if result.code ~= 0 and result.code ~= 1 then return fallback_files(root, opts) end
  local paths = vim.split(result.stdout or "", "\n", { trimempty = true })
  for i, path in ipairs(paths) do paths[i] = vim.fs.joinpath(root, path) end
  return paths
end

local function candidate_command(opts)
  local command = { "rg", "--files-with-matches", "--no-messages", "--hidden" }
  for _, glob in ipairs(source_globs) do vim.list_extend(command, { "--glob", glob }) end
  for _, part in ipairs(opts.exclude or { ".git", "node_modules", "vendor", "target", "build", "dist" }) do
    vim.list_extend(command, { "--glob", "!" .. part .. "/**", "--glob", "!**/" .. part .. "/**" })
  end
  vim.list_extend(command, { candidate_pattern, "." })
  return command
end

function M._candidate_command(opts) return candidate_command(opts or {}) end

function M.discover(root, opts)
  opts = opts or {}
  local cancelled, done = false, false
  local process
  local system = opts.system or vim.system
  if vim.fn.executable("rg") ~= 1 and not opts.system then
    if opts.on_done then opts.on_done(nil, "ripgrep (rg) is required for asynchronous API indexing") end
    return { cancel = function() end }
  end
  process = system(candidate_command(opts), { text = true, cwd = root }, vim.schedule_wrap(function(result)
    if cancelled or done then return end
    done = true
    if result.code ~= 0 and result.code ~= 1 then
      return opts.on_done(nil, result.stderr or ("rg exited with code " .. result.code))
    end
    local paths = vim.split(result.stdout or "", "\n", { trimempty = true })
    for i, path in ipairs(paths) do paths[i] = vim.fs.joinpath(root, path) end
    opts.on_done(paths)
  end))
  return {
    cancel = function()
      if cancelled then return end
      cancelled = true
      if process and type(process.kill) == "function" then pcall(process.kill, process, 15) end
    end,
  }
end

local function scan_path(path, opts)
  local file = io.open(path, "r")
  local text = file and file:read("*a") or nil
  if file then file:close() end
  if not text then return nil, "unable to read file: " .. path end
  return scanner.scan_file(text, path, opts)
end

local function rebuild(state)
  local endpoints, seen, frameworks = {}, {}, {}
  local merged = diagnostics.new()
  for _, report in pairs(state.files) do
    diagnostics.merge(merged, report.diagnostics)
    for _, endpoint in ipairs(report.endpoints or {}) do
      if not seen[endpoint.id] then
        seen[endpoint.id] = true
        endpoints[#endpoints + 1] = endpoint
        frameworks[endpoint.framework] = (frameworks[endpoint.framework] or 0) + 1
      end
    end
  end
  table.sort(endpoints, model.compare)
  state.endpoints, state.diagnostics, state.frameworks = endpoints, merged, frameworks
end

local function matches(endpoint, opts)
  if not opts.method or opts.method == "" then return true end
  return vim.tbl_contains(endpoint.methods or {}, tostring(opts.method):upper())
end

function M.refresh_file(path, opts, on_done)
  opts = opts or {}
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local root = normalize_root(opts.root or vim.fn.getcwd())
  local state = M.state(root)
  local report, err = scan_path(path, opts)
  if report then
    state.files[path] = report
  else
    state.files[path] = nil
    diagnostics.add(state.diagnostics, { file = path }, err)
  end
  rebuild(state)
  state.status = "ready"
  state.stale_files[path] = nil
  if on_done then on_done(err, state) end
  return state
end

local function root_for_path(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local best
  for root in pairs(roots) do
    if path == root or vim.startswith(path, root .. "/") then
      if not best or #root > #best then best = root end
    end
  end
  return best or normalize_root(vim.fn.getcwd())
end

function M.invalidate(path, opts)
  opts = opts or {}
  local root = root_for_path(path)
  if not root then return end
  local state = M.state(root)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  state.stale_files[path] = true
  if state.status == "ready" then state.status = "stale" end
  if state.timer then state.timer:stop(); state.timer:close(); state.timer = nil end
  local delay = opts.cache and opts.cache.debounce_ms or opts.debounce_ms or 400
  state.timer = vim.defer_fn(function()
    state.timer = nil
    local files = state.stale_files
    state.stale_files = {}
    for changed in pairs(files) do M.refresh_file(changed, vim.tbl_extend("force", opts, { root = root })) end
  end, delay)
end

function M.parse_candidates(paths, opts)
  opts = opts or {}
  local cancelled, cursor, done = false, 1, false
  local working = { files = {}, endpoints = {}, diagnostics = diagnostics.new(), seen = {} }
  local budget_ns = (opts.parse_budget_ms or 6) * 1e6
  local now = opts.now or (vim.uv or vim.loop).hrtime
  local schedule = opts.schedule or vim.schedule
  local function finish(err)
    if done then return end
    done = true
    if opts.on_done then opts.on_done(err, err and nil or working) end
  end
  local function step()
    if cancelled then return finish("cancelled") end
    local started = now()
    while cursor <= #paths do
      if cancelled then return finish("cancelled") end
      local path = paths[cursor]
      cursor = cursor + 1
      local report, err = (opts.scan_path or scan_path)(path, opts)
      if report then
        working.files[path] = report
        diagnostics.merge(working.diagnostics, report.diagnostics)
        for _, endpoint in ipairs(report.endpoints or {}) do
          if not working.seen[endpoint.id] then
            working.seen[endpoint.id] = true
            working.endpoints[#working.endpoints + 1] = endpoint
            working.frameworks = working.frameworks or {}
            local framework = endpoint.framework or "unknown"
            working.frameworks[framework] = (working.frameworks[framework] or 0) + 1
            if opts.on_item then opts.on_item(endpoint, cursor - 1, #paths) end
          end
        end
      elseif err then diagnostics.add(working.diagnostics, { file = path }, err) end
      if now() - started >= budget_ns then return schedule(step) end
    end
    finish()
  end
  schedule(step)
  return {
    cancel = function() cancelled = true end,
    running = function() return not done end,
  }
end

function M.finder(opts, _item_for)
  opts = vim.tbl_deep_extend("force", {}, (opts or {}).scan or {}, opts or {})
  local root = normalize_root(opts.root or vim.fn.getcwd())
  local state = M.state(root)
  if state.status == "ready" and not opts.force then
    local result = {}
    for _, endpoint in ipairs(state.endpoints) do
      if matches(endpoint, opts) then result[#result + 1] = endpoint end
    end
    return result
  end
  return function(_, ctx)
    return function(cb)
    local async = assert(ctx.async, "API Query finder requires Snacks async context")
    local generation = M._begin_generation(state)
    local working
    local completed, cancelled = false, false
    local discovery
    local parsing
    local function finish(err, value)
      if completed then return end
      completed = true
      if not err and state.generation == generation then M._commit(state, generation, value) end
      async:resume()
    end
    discovery = M.discover(root, vim.tbl_extend("force", opts, {
      on_done = function(paths, err)
        if cancelled then return end
        if err then return finish(err) end
        parsing = M.parse_candidates(paths or {}, vim.tbl_extend("force", opts, {
          on_item = function(endpoint)
            if not cancelled and state.generation == generation and matches(endpoint, opts) then cb(endpoint) end
          end,
          on_done = function(parse_err, value) finish(parse_err, value) end,
        }))
      end,
    }))
    async:on("abort", function()
      cancelled = true
      if discovery then discovery.cancel() end
      if parsing then parsing.cancel() end
      if not completed then completed = true; async:resume() end
    end)
    if not completed then async:suspend() end
    end
  end
end

function M.scan_root(root, opts)
  opts = opts or {}; root = normalize_root(root)
  local state = M.state(root)
  state.files, state.endpoints, state.diagnostics = {}, {}, diagnostics.new()
  for _, path in ipairs(candidate_files(root, opts)) do
    local file = io.open(path, "r"); local text = file and file:read("*a") or nil; if file then file:close() end
    if text then local report = scanner.scan_file(text, path, opts); state.files[path] = report; diagnostics.merge(state.diagnostics, report.diagnostics); for _, endpoint in ipairs(report.endpoints) do state.endpoints[#state.endpoints + 1] = endpoint end else diagnostics.add(state.diagnostics, { file = path }, "unable to read file") end
  end
  table.sort(state.endpoints, model.compare); local unique, seen = {}, {}; for _, endpoint in ipairs(state.endpoints) do if not seen[endpoint.id] then seen[endpoint.id] = true; unique[#unique + 1] = endpoint end end; state.endpoints = unique
  rebuild(state)
  state.status = "ready"
  return { endpoints = state.endpoints, files = state.files, diagnostics = state.diagnostics.items, frameworks = state.frameworks }
end
function M.open(opts)
  opts = opts or {}
  opts = vim.tbl_extend("force", opts.scan or {}, opts)
  local root = normalize_root(opts.root or vim.fn.getcwd())
  local state = M.state(root)
  if state.status ~= "ready" or opts.force then
    vim.notify("restful: indexing endpoints...", vim.log.levels.INFO)
    vim.cmd("redraw")
    local started = (vim.uv or vim.loop).hrtime()
    M.scan_root(root, opts)
    local elapsed = ((vim.uv or vim.loop).hrtime() - started) / 1e9
    vim.notify(string.format("restful: indexed %d endpoints in %.2fs", #state.endpoints, elapsed), vim.log.levels.INFO)
  end
  return state.endpoints
end
function M.refresh(opts)
  opts = vim.tbl_deep_extend("force", {}, (opts or {}).scan or {}, opts or {})
  opts.root = normalize_root(opts.root or vim.fn.getcwd()); local state = M.state(opts.root)
  local generation = M._begin_generation(state)
  local job
  job = M.discover(opts.root, vim.tbl_extend("force", opts, {
      on_done = function(paths, err)
        if err or state.generation ~= generation then
        if state.generation == generation then
          state.status = has_endpoints(state) and "ready" or "error"
          state.error = err
        end
        return
      end
      M.parse_candidates(paths or {}, vim.tbl_extend("force", opts, {
        on_done = function(parse_err, working)
          if not parse_err and working and state.generation == generation then M._commit(state, generation, working) end
          if parse_err and state.generation == generation then state.status = has_endpoints(state) and "ready" or "error"; state.error = parse_err end
        end,
      }))
    end,
  }))
  return job
end
function M.list(root) return M.state(root).endpoints end
function M.frameworks(root)
  local result = {}
  for name, count in pairs(M.state(root).frameworks or {}) do result[name] = count end
  return result
end
M.candidate_files = candidate_files
return M
