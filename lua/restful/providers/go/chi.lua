-- Function signatures:
--   detect(context) -> detection|nil
--   candidate_patterns(detection) -> string[]
--   extract(context, file, tree) -> fragment[]
--   resolve(context, fragments, graph) -> endpoint[]

local M = { id = "chi", languages = { "go" } }
local METHODS = { Get = "GET", Post = "POST", Put = "PUT", Patch = "PATCH", Delete = "DELETE", Head = "HEAD", Options = "OPTIONS", Connect = "CONNECT", Trace = "TRACE", Method = "ANY" }

local function loc(file, line) return { file = file, line = line, column = 1 } end
local function path(value)
  value = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"', ""):gsub('"$', "")
  return value == "" and "/" or value
end

function M.detect(context)
  local text = (context and (context.text or context.source)) or ""
  if text:match("go%-chi/chi") or text:match("chi%.NewRouter%s*%(") or text:match("%.Route%s*%(") and text:match("%.Get%s*%(") then
    return { id = M.id, language = "go" }
  end
end

function M.candidate_patterns() return { "go-chi/chi", "chi.NewRouter", ".Route", ".Group", ".Mount", ".Get", ".Post" } end

function M.extract(context, file)
  local text = (context and (context.text or context.source)) or ""
  local fragments, line_no = {}, 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local receiver, method, route, handler = line:match("([%w_%.]+)%.([%a]+)%s*%(%s*([^,]+),%s*([^%)]+)")
    if receiver and METHODS[method] and route and handler then
      table.insert(fragments, { kind = "route", framework = M.id, receiver = receiver, method = METHODS[method], path = path(route), handler_name = handler:gsub("^%s+", ""):gsub("%s+$", ""), location = loc(file, line_no) })
    else
      local child, parent, prefix = line:match("([%w_]+)%s*:%=%s*([%w_%.]+)%.Route%s*%(%s*([^,]+),")
      if not child then
        child, parent, prefix = line:match("([%w_]+)%s*=%s*([%w_%.]+)%.Route%s*%(%s*([^,]+),")
      end
      if not child then
        parent, prefix = line:match("([%w_%.]+)%.Route%s*%(%s*([^,]+),")
        child = parent
      end
      if parent and prefix then
        table.insert(fragments, { kind = "prefix", framework = M.id, receiver = child, parent = parent, prefix = path(prefix), location = loc(file, line_no) })
      else
        local group_parent = line:match("([%w_%.]+)%.Group%s*%(%s*func%s*%(")
        if group_parent then
          table.insert(fragments, { kind = "scope", framework = M.id, receiver = group_parent, parent = group_parent, prefix = "", location = loc(file, line_no) })
        end
        local mount_parent, mount_path, mounted = line:match("([%w_%.]+)%.Mount%s*%(%s*([^,]+),%s*([^%)]+)")
        if mount_parent and mount_path and mounted then
          table.insert(fragments, { kind = "mount", framework = M.id, receiver = mounted:gsub("^%s+", ""):gsub("%s+$", ""), parent = mount_parent, prefix = path(mount_path), target = mounted:gsub("^%s+", ""):gsub("%s+$", ""), location = loc(file, line_no) })
        end
      end
    end
  end
  return fragments
end

function M.resolve(_, fragments)
  local prefixes, result = {}, {}
  for _, fragment in ipairs(fragments or {}) do
    if fragment.kind == "prefix" or fragment.kind == "mount" then
      prefixes[fragment.receiver] = path((prefixes[fragment.parent] or "") .. "/" .. fragment.prefix)
    elseif fragment.kind == "route" then
      local declaration = loc(fragment.location.file, fragment.location.line)
      local prefix = prefixes[fragment.receiver] or ""
      table.insert(result, { kind = "server", framework = M.id, language = "go", methods = { fragment.method }, path = path(prefix .. "/" .. fragment.path), raw_path = fragment.path, handler = declaration, declaration = declaration, handler_name = fragment.handler_name, parameters = {}, middleware = {}, provenance = {}, confidence = "partial", diagnostics = {} })
    end
  end
  return result
end

return M
