---@param context table
---@param file string|table
---@param tree table|string|nil
---@return table[] fragments
---@param context table
---@param fragments table[]
---@param graph table|nil
---@return table[] endpoints

local M = { id = "nest", languages = { "typescript", "javascript" } }
local method_names = { Get = "GET", Post = "POST", Put = "PUT", Patch = "PATCH", Delete = "DELETE", Head = "HEAD", Options = "OPTIONS", All = "ALL" }

local function source(file, tree) return type(tree) == "string" and tree or (type(file) == "table" and (file.source or file.text or file.content) or file or "") end
local function value(s)
  if not s then return "" end
  local _, quoted = s:match("^%s*(['\"])(.-)%1")
  return quoted or s:match("^%s*`(.-)`") or ""
end
local function loc(file, line) return { file = type(file) == "table" and (file.path or file.filename) or file, line = line, column = 1 } end

function M.detect(context)
  local p = (context or {}).package_json or ""
  return p:find("@nestjs/", 1, true) and { framework = "nest", language = "typescript" } or nil
end
function M.candidate_patterns() return { "@Controller", "@Get", "@Post", "@Param", "@Query", "@Body", "@Headers" } end

function M.extract(context, file, tree)
  local text, out, line_no, controller = source(file, tree), {}, 0, nil
  local pending = {}
  for line in text:gmatch("([^\n]*)\n?") do
    line_no = line_no + 1
    local cp = line:match("@Controller%s*%((.-)%)")
    if cp then controller = value(cp); out[#out + 1] = { kind = "controller", path = controller, location = loc(file, line_no) } end
    local decorator, arg = line:match("@(%u%a*)%s*%((.-)%)")
    if decorator and method_names[decorator] then pending = { method = method_names[decorator], path = value(arg), location = loc(file, line_no) } end
    for param_decorator, param_arg in line:gmatch("@([%w]+)%s*%(([^)]*)%)") do
      if param_decorator == "Param" or param_decorator == "Query" or param_decorator == "Body" or param_decorator == "Header" or param_decorator == "Headers" then
        local wire_name = value(param_arg)
        pending.parameters = pending.parameters or {}
        pending.parameters[#pending.parameters + 1] = {
          name = wire_name ~= "" and wire_name or param_decorator,
          wire_name = wire_name,
          location = param_decorator == "Param" and "path" or (param_decorator == "Body" and "body" or "query"),
          source = "declared",
        }
      end
    end
    local name = line:match("function%s+([%w_]+)%s*%(") or line:match("^%s*([%w_]+)%s*%(")
    if pending and name then
      out[#out + 1] = { kind = "route", method = pending.method, path = pending.path or "", controller = controller or "", handler = name, parameters = pending.parameters or {}, location = pending.location }
      pending = {}
    end
  end
  return out
end

local function join(a, b)
  local path = ((a or "") .. "/" .. (b or "")):gsub("//+", "/")
  return path:sub(1, 1) == "/" and path or "/" .. path
end
function M.resolve(context, fragments, graph)
  local prefix, endpoints = "", {}
  for _, f in ipairs(fragments or {}) do
    if f.kind == "controller" then prefix = f.path
    elseif f.kind == "route" then endpoints[#endpoints + 1] = { kind = "server", framework = "nest", language = "typescript", methods = { f.method }, path = join(prefix, f.path), handler = f.location, declaration = f.location, parameters = f.parameters, provenance = { f }, confidence = "confirmed", diagnostics = {} } end
  end
  return endpoints
end

return M
