local M = {}

M.defaults = {
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
  picker = { title = "RESTful", keys = { open = "<c-o>", run = "<c-r>" } },
}

local function merge(dst, src)
  for key, value in pairs(src or {}) do
    if type(value) == "table" and type(dst[key]) == "table" then
      merge(dst[key], value)
    else
      dst[key] = value
    end
  end
  return dst
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.get()
  return M.options or M.setup()
end

return M
