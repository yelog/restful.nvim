---@param context table
---@param file string|table
---@param tree table|string|nil
---@return table[] fragments
---@param context table
---@param fragments table[]
---@param graph table|nil
---@return table[] endpoints

local M = { id = "fastify", languages = { "javascript", "typescript" } }
local methods = { get = true, post = true, put = true, patch = true, delete = true, head = true, options = true }

local function source(context, file, tree)
  if type(tree) == "string" then return tree end
  if type(context) == "table" and type(context.text or context.source) == "string" then return context.text or context.source end
  if type(file) == "table" then return file.source or file.text or file.content or "" end
  if type(file) == "string" then
    local handle = io.open(file, "r")
    if handle then
      local text = handle:read("*a")
      handle:close()
      return text
    end
  end
  return ""
end
local function value(s)
  if not s then return nil end
  local _, quoted = s:match("^%s*(['\"])(.-)%1")
  return quoted or s:match("^%s*`(.-)`") or s:match("^%s*([^,%}%)]*)")
end
local function loc(file, line) return { file = type(file) == "table" and (file.path or file.filename) or file, line = line, column = 1 } end

function M.detect(context)
  local p = (context or {}).package_json or ""
  return p:find("fastify", 1, true) and { framework = "fastify", language = "javascript" } or nil
end
function M.candidate_patterns() return { "fastify", ".route(", ".register(", ".get(" } end

function M.extract(context, file, tree)
  local text, out, line_no = source(context, file, tree), {}, 0
  for line in text:gmatch("([^\n]*)\n?") do
    line_no = line_no + 1
    local receiver, object = line:match("([%w_%.]+)%.route%s*%(%s*%{%s*(.*)")
    if receiver then
      local method = value(object:match("method%s*[:=]%s*([^,}]+)"))
      local path = value(object:match("url%s*[:=]%s*([^,}]+)")) or value(object:match("path%s*[:=]%s*([^,}]+)"))
      if method and path then out[#out + 1] = { kind = "route", receiver = receiver, method = method:upper(), path = path, location = loc(file, line_no) } end
    end
    local r, method, args = line:match("([%w_%.]+)%.([%a]+)%s*%((.*)")
    if r and methods[method:lower()] then
      local path = value(args)
      if path then out[#out + 1] = { kind = "route", receiver = r, method = method:upper(), path = path, location = loc(file, line_no) } end
    end
    local parent, plugin, opts = line:match("([%w_%.]+)%.register%s*%(%s*([%w_%.]+)%s*,%s*(%b{})")
    if parent and plugin and opts then
      local prefix = value(opts:match("prefix%s*:%s*([^,}]+)"))
      if prefix then out[#out + 1] = { kind = "mount", receiver = plugin or "plugin", parent = parent, path = prefix, location = loc(file, line_no) } end
    end
  end
  return out
end

function M.resolve(context, fragments, graph)
  local endpoints, mounts = {}, {}
  for _, f in ipairs(fragments or {}) do
    if f.kind == "mount" then
      mounts[f.receiver] = mounts[f.receiver] or {}
      mounts[f.receiver][#mounts[f.receiver] + 1] = f
    elseif f.kind == "route" then
      local prefixes, seen = {}, {}
      local function expand(name, prefix, depth)
        if depth > 12 or seen[name] then return end
        seen[name] = true
        if not mounts[name] then
          prefixes[#prefixes + 1] = prefix
        else
          for _, mount in ipairs(mounts[name]) do expand(mount.parent, (mount.path or "") .. prefix, depth + 1) end
        end
        seen[name] = nil
      end
      expand(f.receiver, "", 0)
      for _, prefix in ipairs(prefixes) do
        local path = ((prefix or "") .. "/" .. f.path):gsub("//+", "/")
        endpoints[#endpoints + 1] = { kind = "server", framework = "fastify", language = "javascript", methods = { f.method }, path = path, handler = f.location, declaration = f.location, parameters = {}, provenance = { f }, confidence = "confirmed", diagnostics = {} }
      end
    end
  end
  return endpoints
end

return M
