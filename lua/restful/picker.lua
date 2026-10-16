local M = {}

local method_style = {
  GET = { icon = "󰯿", hl = "DiagnosticOk" },
  POST = { icon = "󰰚", hl = "DiagnosticInfo" },
  PUT = { icon = "󰰚", hl = "DiagnosticWarn" },
  PATCH = { icon = "󰰚", hl = "DiagnosticWarn" },
  DELETE = { icon = "󰯶", hl = "DiagnosticError" },
  HEAD = { icon = "󰯿", hl = "DiagnosticHint" },
  OPTIONS = { icon = "󰘳", hl = "DiagnosticHint" },
  TRACE = { icon = "󰕍", hl = "DiagnosticHint" },
  ANY = { icon = "󱎔", hl = "DiagnosticWarn" },
  ALL = { icon = "󱎔", hl = "DiagnosticWarn" },
}

local function notify(message, level)
  vim.notify("restful: " .. message, level or vim.log.levels.INFO)
end

local function location(item)
  return item.handler or item.declaration or item.location
end

local function jump(item)
  local loc = location(item)
  if not loc or not loc.file then return notify("no source location", vim.log.levels.WARN) end
  vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
  local line = math.max(1, loc.line or 1)
  local column = loc.column or 1
  local handler_name = item.handler_name or item.handler and item.handler.name
  if type(handler_name) == "string" and handler_name ~= "" then
    local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
    column = text:find(handler_name, 1, true) or column
  end
  -- cursor() uses the same 1-based byte column as provider locations.
  vim.fn.cursor(line, math.max(1, column))
end

local function label(item)
  local methods = table.concat(item.methods or { item.method or "ANY" }, ",")
  local path = item.path or "<unresolved path>"
  local handler = item.handler_name or item.handler and item.handler.name or ""
  local framework = item.framework and ("  " .. item.framework) or ""
  return string.format("%-16s %-36s %-24s%s", methods, path, handler, framework)
end

local function basename(item)
  local file = item.file or item.handler and item.handler.file or item.declaration and item.declaration.file
  return file and vim.fs.basename(file) or "<unknown>"
end

local function display_name(item)
  return item.description or item.comment or item.summary or item.handler_name or "<anonymous>"
end

local function format_endpoint(item, picker)
  local method = (item.methods and item.methods[1] or item.method or "ANY"):upper()
  local style = method_style[method] or method_style.ANY
  local path = item.path or "<unresolved path>"
  local file = basename(item)
  local name = display_name(item)
  local width = 100
  if picker and picker.list and picker.list.win and picker.list.win.win then
    width = vim.api.nvim_win_get_width(picker.list.win.win)
  end

  local file_width = vim.api.nvim_strwidth(file)
  local file_column = math.max(1, width - file_width - 1)
  local available = math.max(8, file_column - vim.api.nvim_strwidth(style.icon) - 4)
  local left = name .. "  " .. path
  if vim.api.nvim_strwidth(left) > available then left = vim.fn.strcharpart(left, 0, available - 1) .. "…" end
  local shown_name, shown_path = left:match("^(.-)  (.*)$")
  shown_name, shown_path = shown_name or left, shown_path or ""
  return {
    { style.icon .. "  ", style.hl },
    { shown_name, "SnacksPickerFile", field = "text" },
    { shown_path ~= "" and "  " or "" },
    { shown_path, "SnacksPickerComment", field = "text" },
    {
      col = 0,
      virt_text = { { file, "SnacksPickerComment" } },
      virt_text_win_col = file_column,
      hl_mode = "combine",
    },
  }
end

local function item_for(endpoint)
  local path = endpoint.path or "<unresolved path>"
  local name = display_name(endpoint)
  local text = name .. " " .. path
  local item = vim.tbl_extend("force", endpoint, {
    text = text,
    label = text,
    file = endpoint.handler and endpoint.handler.file or endpoint.declaration and endpoint.declaration.file,
    pos = endpoint.handler and { endpoint.handler.line or 1, endpoint.handler.column or 1 }
      or endpoint.declaration and { endpoint.declaration.line or 1, endpoint.declaration.column or 1 },
  })
  return item
end

local function request_action(item, action, context)
  local ok, request = pcall(require, "restful.request")
  if not ok or type(request[action]) ~= "function" then
    return notify("request module does not provide " .. action, vim.log.levels.WARN)
  end
  request[action](item, context)
end

local function choose_fallback(items)
  if #items == 0 then return notify("no indexed endpoints", vim.log.levels.WARN) end
  vim.ui.select(items, {
    prompt = "RESTful",
    format_item = label,
  }, function(item)
    if item then jump(item) end
  end)
end

function M.open(items, opts)
  items = items or {}
  opts = opts or {}
  local keys = opts.keys or (opts.picker and opts.picker.keys) or {}
  local is_finder = type(items) == "function"
  local picker_items = {}
  if not is_finder then for _, item in ipairs(items) do picker_items[#picker_items + 1] = item_for(item) end end
  local snacks = rawget(_G, "Snacks")
  if not snacks or not snacks.picker or type(snacks.picker.pick) ~= "function" then
    if is_finder then return notify("Snacks is required for asynchronous API indexing", vim.log.levels.WARN) end
    return choose_fallback(picker_items)
  end

  local picker_opts = {
    title = opts.title or "RESTful",
    pattern = opts.query,
    show_delay = 0,
    show_empty = true,
    format = format_endpoint,
    confirm = function(picker, item)
      picker:close()
      if item then jump(item) end
    end,
    actions = {
      api_request_open = function(picker)
        request_action(picker:selected(), "open", opts.request)
      end,
      api_request_run = function(picker)
        request_action(picker:selected(), "run", opts.request)
      end,
    },
    win = { input = { keys = {
      ["<c-u>"] = { function() return "<c-g>u<c-u>" end, mode = "i", expr = true, desc = "delete to start of line" },
      [keys.open or "<c-o>"] = { "api_request_open", mode = { "n", "i" } },
      [keys.run or "<c-r>"] = { "api_request_run", mode = { "n", "i" } },
    } } },
  }
  if is_finder then
    picker_opts.finder = function(find_opts, ctx)
      local source = items(find_opts, ctx)
      if type(source) ~= "function" then
        return vim.tbl_map(item_for, source or {})
      end
      return function(cb)
        source(function(item) cb(item_for(item)) end)
      end
    end
  else
    picker_opts.items = picker_items
  end
  return snacks.picker.pick(picker_opts)
end

M.jump = jump
M.label = label
M.item_for = item_for
M.format_endpoint = format_endpoint
M.method_style = method_style
M.display_name = display_name

return M
