-- parse(text, opts) -> { endpoints = endpoint[], fragments = fragment[] }
-- parse_text(text, opts), extract(text, opts) -> same result

local M = { id = "fastapi", languages = { "python" }, framework = "fastapi" }

local function unquote(value)
  if not value then return nil end
  return value:match([[^[%s]*["'](.-)["'][%s]*$]])
end

local function strings(value)
  local result = {}
  for quote, text in value:gmatch([[(["'])(.-)%1]]) do
    result[#result + 1] = text
  end
  return result
end

local function kwarg(line, name)
  return unquote(line:match(name .. [[%s*=%s*(["'][^"']*["'])]]))
end

local function handler_after(lines, index)
  for n = index + 1, math.min(#lines, index + 5) do
    local name = lines[n]:match([[^%s*def%s+([%w_]+)]]) or lines[n]:match([[^%s*async%s+def%s+([%w_]+)]])
    if name then return name end
  end
end

local function result()
  return { endpoints = {}, fragments = {} }
end

function M.parse(text, opts)
  local output = result()
  local lines, prefixes, includes = {}, {}, {}
  for line in (text or ""):gmatch("[^\n]*") do lines[#lines + 1] = line end

  for index, line in ipairs(lines) do
    local variable, prefix = line:match([[([%w_]+)%s*=%s*APIRouter%s*%((.*)%)]])
    if variable then
      prefixes[variable] = kwarg(prefix, "prefix") or ""
    end
    local router, extra = line:match([[%f[%w]include_router%s*%(%s*([%w_]+)(.*)%)]])
    if router then
      extra = extra or ""
      includes[router] = includes[router] or {}
      includes[router][#includes[router] + 1] = kwarg(extra, "prefix") or ""
      output.fragments[#output.fragments + 1] = {
        kind = "include_router", router = router, prefix = kwarg(extra, "prefix") or "", line = index,
      }
    end
  end

  for index, line in ipairs(lines) do
    local object, call, args = line:match([[^%s*@([%w_]+)%.([%w_]+)%s*%((.*)%)]])
    if object and (call == "get" or call == "post" or call == "put" or call == "patch" or call == "delete" or call == "options" or call == "head" or call == "api_route") then
      local values = strings(args or "")
      local path = values[1]
      if path then
        local methods = {}
        if call == "api_route" then
          local method_text = args:match("methods%s*=%s*%[([^%]]*)%]") or ""
          methods = strings(method_text)
        else methods = { call:upper() } end
        if #methods == 0 then methods = { "GET" } end
        local base = prefixes[object] or ""
        for _, include_prefix in ipairs(includes[object] or { "" }) do
          for _, method in ipairs(methods) do
            output.endpoints[#output.endpoints + 1] = {
              method = method:upper(), path = base .. include_prefix .. path,
              handler = handler_after(lines, index), framework = "fastapi", kind = "route", line = index,
            }
          end
        end
      end
    end
  end
  return output
end

M.parse_text = M.parse
M.extract = M.parse
return M
