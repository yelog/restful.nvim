-- Public API:
--   extract(context, file, tree) -> endpoint[]
--   resolve(context, fragments, graph) -> endpoint[]
-- `context.lines`/`context.text` (or file.lines/file.text) is accepted; tree is
-- optional and unused. Returned values use the common endpoint shape.

local M = { id = "jaxrs", languages = { "java" }, framework = "jaxrs", aliases = { "java-jaxrs" } }

local function lines_of(context, file)
  local value = type(context) == "table" and (context.lines or context.text or context.source) or nil
  value = value or (type(file) == "table" and (file.lines or file.text))
  if type(value) == "table" then return value end
  if type(value) == "string" then return vim.split(value, "\n", { plain = true }) end
  return {}
end

local function file_of(context, file)
  if type(file) == "string" then return file end
  if type(file) == "table" then return file.path or file.name or "<buffer>" end
  return type(context) == "table" and (context.file or context.path) or "<buffer>"
end

local function strings(value)
  local result = {}
  for item in (value or ""):gmatch('"([^"\n]*)"') do result[#result + 1] = item end
  if #result == 0 and value and value:gsub("%s+", "") ~= "" then result[1] = value:gsub("^%s+", ""):gsub("%s+$", "") end
  return #result > 0 and result or { "" }
end

local function path_join(a, b)
  if not a or a == "" then return b == "" and "/" or (b:sub(1, 1) == "/" and b or "/" .. b) end
  if not b or b == "" then return a:sub(1, 1) == "/" and a or "/" .. a end
  local left = a:gsub("/+$", "")
  local right = b:gsub("^/+", "")
  return left .. "/" .. right
end

local function route(line)
  local name, args = line:match("@([%w_]+)%s*%((.*)%)")
  name = name or line:match("@([%w_]+)")
  if not name then return nil end
  local methods = { GET = "GET", POST = "POST", PUT = "PUT", DELETE = "DELETE", PATCH = "PATCH", HEAD = "HEAD", OPTIONS = "OPTIONS" }
  if methods[name] then return { paths = { "" }, methods = { methods[name] }, name = name } end
  if name == "Path" then return { paths = strings(args), methods = nil, name = name } end
  return nil
end

local function param(text, file, line)
  local name, args = text:match("@([%w_]+)%s*%((.-)%)")
  name = name or text:match("@([%w_]+)")
  local locations = { PathParam = "path", QueryParam = "query", HeaderParam = "header", CookieParam = "cookie", FormParam = "form" }
  local where = locations[name]
  if not where and name ~= "BeanParam" then return nil end
  local wire = args and (args:match('"([^"]+)"') or args:match("value%s*=%s*([^,%s]+)"))
  local clean = text:gsub("@[%w_]+%s*%b()", ""):gsub("@[%w_]+", "")
  local variable = clean:match("([%w_]+)%s*$") or wire or "value"
  return { name = variable, wire_name = wire or variable, location = where or "query", source = "declared", location_ref = { file = file, line = line, column = 1 } }
end

function M.extract(context, file, _tree)
  local source, filename, result = lines_of(context, file), file_of(context, file), {}
  local class_path, pending = "", {}
  for number, line in ipairs(source) do
    local found = route(line)
    if found then
      if found.name == "Path" and class_path == "" then class_path = found.paths[1] end
      pending[#pending + 1] = { value = found, line = number }
    end
    if line:match("class%s+[%w_]+") or line:match("interface%s+[%w_]+") then
      for _, item in ipairs(pending) do if item.value.name == "Path" then class_path = item.value.paths[1] end end
      pending = {}
    elseif line:find("%(") and not line:match("^%s*//") then
      local signature, cursor = line, number
      while not signature:find("%)") and cursor < #source do cursor = cursor + 1; signature = signature .. " " .. source[cursor] end
      local params = {}
      local arguments = signature:match("%((.*)%)") or ""
      for part in arguments:gmatch("[^,]+") do local value = param(part, filename, number); if value then params[#params + 1] = value end end
      for _, item in ipairs(pending) do
        if item.value.name ~= "Path" then
          for _, method_path in ipairs(item.value.paths) do
            local path = path_join(class_path, method_path)
            result[#result + 1] = { id = table.concat({ "jaxrs", filename, item.line, path, table.concat(item.value.methods, ",") }, "|"), kind = "server", framework = "jaxrs", language = "java", methods = item.value.methods, path = path, raw_path = path, parameters = params, handler = { file = filename, line = number, column = 1 }, declaration = { file = filename, line = item.line, column = 1 }, body = nil, middleware = {}, provenance = { "@" .. item.value.name }, confidence = "confirmed", diagnostics = {} }
          end
        end
      end
      pending = {}
    end
  end
  return result
end

function M.resolve(_context, fragments, _graph) return fragments or {} end

return M
