---Request draft materialization and the small Neovim/Kulala adapter around it.

local M = {}

local SAFE_METHODS = { GET = true, HEAD = true, OPTIONS = true }
local VALID_METHODS = {
  GET = true, HEAD = true, OPTIONS = true, POST = true, PUT = true,
  PATCH = true, DELETE = true, TRACE = true, CONNECT = true,
}

local function list(value)
  if value == nil then return {} end
  if type(value) == "table" and value[1] ~= nil then return value end
  return { value }
end

local function add_unique(result, seen, value)
  if value and value ~= "" and not seen[value] then
    seen[value] = true
    result[#result + 1] = value
  end
end

local function encode(value)
  value = tostring(value)
  return (value:gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function json(value)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif kind == "table" then
    local is_array = value[1] ~= nil
    local parts = {}
    if is_array then
      for _, item in ipairs(value) do parts[#parts + 1] = json(item) end
      return "[" .. table.concat(parts, ", ") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("%q: %s", key, json(value[key]))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "null"
end

local function values_for(context, parameter)
  local name = parameter.wire_name or parameter.name
  local values = context.values or context.params or {}
  local value = values[name]
  if value == nil and name ~= parameter.name then value = values[parameter.name] end
  if value == nil then value = parameter.value or parameter.example or parameter.default end
  return list(value)
end

local function variable_name(parameter)
  return parameter.variable or parameter.wire_name or parameter.name
end

local function placeholder(parameter)
  return "{{" .. variable_name(parameter) .. "}}"
end

local function parameter_groups(endpoint)
  local groups = { path = {}, query = {}, header = {}, body = {}, form = {}, multipart = {} }
  for _, parameter in ipairs(list(endpoint.parameters)) do
    if type(parameter) == "string" then
      parameter = { name = parameter, location = "query" }
    end
    local location = parameter.location or parameter["in"] or "query"
    if groups[location] then groups[location][#groups[location] + 1] = parameter end
  end
  return groups
end

local function resolve_path(path, parameters, context, unresolved)
  local function replace(name)
    local parameter
    for _, candidate in ipairs(parameters) do
      if (candidate.name or candidate.wire_name) == name
          or candidate.wire_name == name then
        parameter = candidate
        break
      end
    end
    parameter = parameter or { name = name, location = "path" }
    local values = values_for(context, parameter)
    if parameter.secret or #values == 0 or values[1] == nil then
      add_unique(unresolved, unresolved._seen, variable_name(parameter))
      return placeholder(parameter)
    end
    return encode(values[1])
  end
  path = path:gsub("{([%w_%-]+)}", replace)
  path = path:gsub(":([%w_%-]+)", replace)
  return path:gsub("<([%w_%-]+)>", replace)
end

local function base_url(context)
  return context.services_url or context.runtime_url or context.base_url
    or context.base_url_value
    or (context.base_url_variable and "{{" .. context.base_url_variable .. "}}")
    or context.fallback_base_url
    or "http://localhost:8080"
end

local function join_url(base, path)
  if base:sub(-1) == "/" and path:sub(1, 1) == "/" then return base .. path:sub(2) end
  if base:sub(-1) ~= "/" and path:sub(1, 1) ~= "/" then return base .. "/" .. path end
  return base .. path
end

local function add_parameter_lines(lines, parameters, context, unresolved, separator)
  for _, parameter in ipairs(parameters) do
    local values = values_for(context, parameter)
    if parameter.secret or #values == 0 or values[1] == nil then
      add_unique(unresolved, unresolved._seen, variable_name(parameter))
      values = { placeholder(parameter) }
    end
    for _, value in ipairs(values) do
      lines[#lines + 1] = { name = parameter.wire_name or parameter.name, value = value, separator = separator }
    end
  end
end

---Build a Kulala-compatible request without reading environment or secret values.
---@return table { lines: string[], unresolved: string[] }
function M.materialize(endpoint, context)
  endpoint = endpoint or {}
  context = context or {}
  local unresolved = { _seen = {} }
  local groups = parameter_groups(endpoint)
  local method = string.upper(endpoint.method or (endpoint.methods and endpoint.methods[1]) or "GET")
  if not VALID_METHODS[method] then method = "GET" end
  local path = endpoint.path or endpoint.raw_path or "/"
  path = resolve_path(path, groups.path, context, unresolved)
  local query = {}
  add_parameter_lines(query, groups.query, context, unresolved, "=")
  local url = join_url(tostring(base_url(context)), path)
  if #query > 0 then
    local encoded = {}
    for _, item in ipairs(query) do encoded[#encoded + 1] = encode(item.name) .. "=" .. encode(item.value) end
    url = url .. (url:find("?", 1, true) and "&" or "?") .. table.concat(encoded, "&")
  end

  local lines = { method .. " " .. url }
  local headers = {}
  add_parameter_lines(headers, groups.header, context, unresolved, ":")
  for _, header in ipairs(headers) do lines[#lines + 1] = header.name .. ": " .. tostring(header.value) end

  local body = endpoint.body
  if body == nil and (#groups.body + #groups.form + #groups.multipart > 0) then
    body = {}
    for _, parameter in ipairs(groups.body) do
      local values = values_for(context, parameter)
      body[parameter.wire_name or parameter.name] = parameter.secret and placeholder(parameter)
        or values[1] or placeholder(parameter)
      if parameter.secret or values[1] == nil then add_unique(unresolved, unresolved._seen, variable_name(parameter)) end
    end
  end
  if body ~= nil then
    local content_type = endpoint.content_type or "application/json"
    lines[#lines + 1] = "Content-Type: " .. content_type
    lines[#lines + 1] = ""
    lines[#lines + 1] = type(body) == "string" and body or json(body)
  end
  lines[#lines + 1] = ""
  unresolved._seen = nil
  return { lines = lines, unresolved = unresolved }
end

local function notify(message, level)
  if vim and vim.notify then vim.notify(message, level or vim.log.levels.WARN) end
end

function M.open(endpoint, context)
  if not vim or not vim.api then return nil, "Neovim API is unavailable" end
  local draft = M.materialize(endpoint, context)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, draft.lines)
  vim.bo[bufnr].filetype = "http"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, draft
end

function M.run(endpoint, context)
  context = context or {}
  local draft = M.materialize(endpoint, context)
  local path_unresolved = false
  for _, name in ipairs(draft.unresolved) do
    for _, parameter in ipairs(list(endpoint.parameters)) do
      if parameter.location == "path" and (parameter.name == name or parameter.wire_name == name) then
        path_unresolved = true
      end
    end
  end
  if path_unresolved then notify("API request has unresolved path variables") return nil, "unresolved path" end
  local method = string.upper(endpoint.method or (endpoint.methods and endpoint.methods[1]) or "GET")
  if not SAFE_METHODS[method] and context.confirm_unsafe_methods ~= false then
    local confirm = context.confirm
    if not confirm and vim and vim.fn and vim.fn.confirm then
      confirm = function(message)
        return vim.fn.confirm(message, "&Send\n&Cancel", 2) == 1
      end
    end
    if not confirm then notify("Unsafe API request not sent; confirmation is unavailable") return nil, "confirmation unavailable" end
    local accepted = confirm("Send " .. method .. " request?", { kind = "warning" })
    if accepted == false then return nil, "cancelled" end
  end
  local kulala = context.kulala
  local ok = kulala ~= nil
  if not kulala then ok, kulala = pcall(require, "kulala") end
  if not ok or not kulala or type(kulala.run) ~= "function" then
    notify("Kulala is not installed; opened request draft instead")
    return M.open(endpoint, context)
  end
  local bufnr = M.open(endpoint, context)
  if context.runner then context.runner() else kulala.run() end
  return bufnr, draft
end

return M
