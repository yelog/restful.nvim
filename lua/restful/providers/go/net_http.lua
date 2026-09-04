-- Function signatures:
--   detect(context) -> detection|nil
--   candidate_patterns(detection) -> string[]
--   extract(context, file, tree) -> fragment[]
--   resolve(context, fragments, graph) -> endpoint[]

local M = {
  id = "net_http",
  languages = { "go" },
}

local METHODS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true, CONNECT = true, TRACE = true }

local function location(file, line, column)
  return { file = file, line = line, column = column or 1 }
end

local function clean_path(path)
  path = path:gsub("^%s+", ""):gsub("%s+$", "")
  path = path:gsub("^\"", ""):gsub("\"$", "")
  return path == "" and "/" or path
end

local function endpoint(method, path, handler, declaration, raw_path)
  return {
    kind = "server", framework = "net_http", language = "go", methods = { method },
    path = clean_path(path), raw_path = raw_path or path, handler = handler,
    declaration = declaration, parameters = {}, middleware = {}, provenance = {},
    confidence = "partial", diagnostics = {},
  }
end

function M.detect(context)
  local text = (context and (context.text or context.source)) or ""
  if text:match("net/http") or text:match("http%.HandleFunc") or text:match("http%.Handle%s*%(") then
    return { id = M.id, language = "go" }
  end
end

function M.candidate_patterns()
  return { "net/http", "http.Handle", "http.HandleFunc", ":Handle", ":HandleFunc" }
end

function M.extract(context, file)
  local text = (context and (context.text or context.source)) or ""
  local fragments = {}
  local line_no = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local receiver, method, path, handler = line:match("([%w_%.]+)%.(HandleFunc)%s*%(%s*([^,]+),%s*([^%)]+)")
    if receiver and path and handler then
      local verb, route = clean_path(path):match("^(%u+)%s+(.+)$")
      table.insert(fragments, { kind = "route", framework = M.id, receiver = receiver, method = METHODS[verb] and verb or "ANY", path = route or path, handler_name = handler:gsub("^%s+", ""):gsub("%s+$", ""), location = location(file, line_no) })
    else
      local recv, pattern, fn = line:match("([%w_%.]+)%.Handle%s*%(%s*([^,]+),%s*([^%)]+)")
      if recv and pattern and fn then
        local verb, route = clean_path(pattern):match("^(%u+)%s+(.+)$")
        table.insert(fragments, { kind = "route", framework = M.id, receiver = recv, method = METHODS[verb] and verb or "ANY", path = route or pattern, handler_name = fn:gsub("^%s+", ""):gsub("%s+$", ""), location = location(file, line_no) })
      end
    end
  end
  return fragments
end

function M.resolve(_, fragments)
  local result = {}
  for _, fragment in ipairs(fragments or {}) do
    if fragment.kind == "route" then
      local handler = location(fragment.location.file, fragment.location.line)
      table.insert(result, endpoint(fragment.method, fragment.path, handler, handler, fragment.path))
      result[#result].handler_name = fragment.handler_name
    end
  end
  return result
end

return M
