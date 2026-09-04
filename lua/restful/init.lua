local M = {}
local config = require("restful.config")

local function notify(message, level)
  vim.notify("restful: " .. message, level or vim.log.levels.INFO)
end

local function index_module()
  local ok, index = pcall(require, "restful.index")
  if not ok then
    notify("index module is not available", vim.log.levels.WARN)
    return nil
  end
  return index
end

local function endpoints(index, opts)
  if type(index.query) == "function" then return index.query(opts or {}) end
  if type(index.list) == "function" then return index.list(opts or {}) end
  if type(index.endpoints) == "function" then return index.endpoints(opts or {}) end
  if type(index.items) == "function" then return index.items(opts or {}) end
  if type(index.get) == "function" then return index.get(opts or {}) end
  return index.endpoints or index.items or {}
end

local methods = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true, TRACE = true, CONNECT = true, ANY = true, ALL = true }

function M.setup(opts)
  local options = config.setup(opts)
  local providers = require("restful.providers")
  for _, provider in ipairs(options.providers or {}) do
    if not providers.get(provider.id) then providers.register(provider) end
  end
  if vim.fn.exists(":Restful") == 0 then
    vim.api.nvim_create_user_command("Restful", function(command)
      local args = vim.split(command.args or "", "%s+", { trimempty = true })
      local method = methods[(args[1] or ""):upper()] and (args[1] or ""):upper() or nil
      local query_start = method and 2 or 1
      M.open({ method = method, query = table.concat(vim.list_slice(args, query_start), " ") })
    end, { nargs = "*", desc = "Search source API endpoints" })
    vim.api.nvim_create_user_command("RestfulRefresh", function(command) M.refresh(command.bang == 1) end, { bang = true })
    vim.api.nvim_create_user_command("RestfulDiagnostics", M.diagnostics, {})
    vim.api.nvim_create_user_command("RestfulFrameworks", M.frameworks, {})
  end
  local group = vim.api.nvim_create_augroup("RestfulIndex", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = group,
    pattern = { "*.java", "*.py", "*.go", "*.js", "*.jsx", "*.ts", "*.tsx" },
    callback = function(args)
      local index = index_module()
      if index and type(index.invalidate) == "function" then index.invalidate(args.file, config.get()) end
    end,
  })
  return options
end

function M.open(opts)
  local index = index_module()
  if not index then return end
  opts = vim.tbl_deep_extend("force", {}, config.get(), opts or {})
  local picker = require("restful.picker")
  if type(index.finder) == "function" then
    return picker.open(index.finder(opts, picker.item_for), vim.tbl_deep_extend("force", {}, opts.picker or {}, opts))
  end
  if type(index.open) == "function" then return picker.open(index.open(opts), opts.picker or opts) end
  return picker.open(endpoints(index, opts), vim.tbl_deep_extend("force", {}, opts.picker or {}, opts))
end

function M.refresh(force)
  local index = index_module()
  if not index then return end
  if type(index.refresh) ~= "function" then return notify("index does not support refresh", vim.log.levels.WARN) end
  index.refresh(vim.tbl_extend("force", config.get(), { force = force == true }))
end

function M.diagnostics()
  local index = index_module()
  if not index then return end
  local items = require("restful.diagnostics").to_qflist(index.state(vim.fn.getcwd()).diagnostics)
  vim.fn.setqflist({}, "r", { title = "RESTful diagnostics", items = items })
  if #items > 0 then vim.cmd("copen") else notify("no diagnostics") end
end

function M.frameworks()
  local index = index_module()
  if not index then return end
  local list = type(index.frameworks) == "function" and index.frameworks(vim.fn.getcwd()) or index.frameworks or {}
  local lines = {}
  for name, value in pairs(list) do lines[#lines + 1] = name .. " " .. tostring(value) end
  table.sort(lines)
  vim.notify(#lines > 0 and table.concat(lines, "\n") or "no frameworks detected")
end

function M.register_provider(provider)
  return require("restful.providers").register(provider)
end

return M
