---@param context table
---@param file string|table
---@param tree table|string|nil
---@return table[] fragments
---@param context table
---@param fragments table[]
---@param graph table|nil
---@return table[] endpoints

local M = { id = "express", languages = { "javascript", "typescript" } }

local methods = { get = true, post = true, put = true, patch = true, delete = true, head = true, options = true, all = true }

local function source(file, tree)
  if type(tree) == "string" then return tree end
  if type(file) == "string" then
    local handle = io.open(file, "r")
    if handle then
      local text = handle:read("*a")
      handle:close()
      return text
    end
  end
  return (type(file) == "table" and (file.source or file.text or file.content)) or ""
end

local function unquote(value)
  if not value then return nil end
  local quote, text = value:match("^%s*(['\"])(.-)%1")
  return text or (value:match("^%s*`(.-)`") or value:match("^%s*([^,%)]*)"))
end

local function loc(file, line, column)
  return { file = type(file) == "table" and (file.path or file.filename) or file, line = line, column = column or 1 }
end

local function add(out, item)
  item.kind = item.kind or "route"
  item.provider = "express"
  out[#out + 1] = item
end

function M.detect(context)
  local package_json = (context or {}).package_json or ""
  return package_json:find([=["express"]=], 1, true) and { framework = "express", language = "javascript" } or nil
end

function M.candidate_patterns()
  return { "express", "Router", "app.use", ".get(", ".post(" }
end

function M.extract(context, file, tree)
  local text, out = source(file, tree), {}
  local line_no = 0
  for line in text:gmatch("([^\n]*)\n?") do
    line_no = line_no + 1
    local receiver, method, args = line:match("([%w_%.]+)%.([%a]+)%s*%((.*)")
    if receiver and methods[method:lower()] then
      local path = unquote(args)
      if path then add(out, { kind = "route", receiver = receiver, method = method:upper(), path = path, location = loc(file, line_no) }) end
    end
    local mount_receiver, _, mount_path, child = line:match("([%w_%.]+)%.use%s*%(%s*(['\"])(.-)%2%s*,%s*([%w_%.]+)")
    if mount_receiver and mount_path and child then
      add(out, { kind = "mount", receiver = child, parent = mount_receiver, path = mount_path, location = loc(file, line_no) })
    end
    local parent, route_path, chain = line:match("([%w_%.]+)%.route%s*%(%s*(['\"])(.-)%2%s*%)%s*(.*)")
    if parent and route_path then
      for cm, ca in chain:gmatch("%.([%a]+)%s*%(([^)]*)%)") do
        if methods[cm:lower()] then add(out, { kind = "route", receiver = parent, method = cm:upper(), path = route_path, location = loc(file, line_no) }) end
      end
    end
  end
  return out
end

local function join(a, b)
  a, b = a or "", b or ""
  if a == "/" then a = "" end
  if b == "/" then b = "" end
  return (a .. "/" .. b):gsub("//+", "/")
end

function M.resolve(context, fragments, graph)
  local endpoints, mounts = {}, {}
  for _, f in ipairs(fragments or {}) do
    if f.kind == "mount" then mounts[f.receiver] = mounts[f.receiver] or {}; mounts[f.receiver][#mounts[f.receiver] + 1] = f
    elseif f.kind == "route" then
      local prefixes, seen = {}, {}
      local function expand(name, prefix, depth)
        if depth > 12 or seen[name] then return end
        seen[name] = true
        local parents = mounts[name]
        if not parents then
          prefixes[#prefixes + 1] = prefix
        else
          for _, m in ipairs(parents) do expand(m.parent, join(m.path, prefix), depth + 1) end
        end
        seen[name] = nil
      end
      expand(f.receiver, "", 0)
      for _, p in ipairs(prefixes) do endpoints[#endpoints + 1] = { kind = "server", framework = "express", language = "javascript", methods = { f.method }, path = join(p, f.path), handler = f.location, declaration = f.location, parameters = {}, provenance = { f }, confidence = "confirmed", diagnostics = {} } end
    end
  end
  return endpoints
end

return M
