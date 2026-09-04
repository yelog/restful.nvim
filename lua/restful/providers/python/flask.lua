-- parse(text, opts) -> { endpoints = endpoint[], fragments = fragment[] }
-- parse_text(text, opts), extract(text, opts) -> same result

local M = { id = "flask", languages = { "python" }, framework = "flask" }

local function unquote(value)
  if not value then return nil end
  return value:match([[^[%s]*["'](.-)["'][%s]*$]])
end

local function strings(value)
  local result = {}
  for quote, text in value:gmatch([[(["'])(.-)%1]]) do result[#result + 1] = text end
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

function M.parse(text, opts)
  local output, lines, prefixes, includes = { endpoints = {}, fragments = {} }, {}, {}, {}
  for line in (text or ""):gmatch("[^\n]*") do lines[#lines + 1] = line end
  for index, line in ipairs(lines) do
    local variable, args = line:match([[([%w_]+)%s*=%s*Blueprint%s*%((.*)%)]])
    if variable then prefixes[variable] = kwarg(args, "url_prefix") or "" end
    local blueprint, extra = line:match([[register_blueprint%s*%(%s*([%w_]+)(.*)%)]])
    if blueprint then
      includes[blueprint] = includes[blueprint] or {}
      includes[blueprint][#includes[blueprint] + 1] = kwarg(extra or "", "url_prefix") or ""
      output.fragments[#output.fragments + 1] = { kind = "register_blueprint", blueprint = blueprint, prefix = kwarg(extra or "", "url_prefix") or "", line = index }
    end
  end
  for index, line in ipairs(lines) do
    local object, call, args = line:match([[^%s*@([%w_]+)%.([%w_]+)%s*%((.*)%)]])
    if object and call == "route" then
      local values, path = strings(args), nil
      path = values[1]
      if path then
        local methods = strings(args:match("methods%s*=%s*%[([^%]]*)%]") or "")
        if #methods == 0 then methods = { "GET" } end
        local base = prefixes[object] or ""
        for _, registered in ipairs(includes[object] or { "" }) do
          for _, method in ipairs(methods) do
            output.endpoints[#output.endpoints + 1] = {
              method = method:upper(), path = base .. registered .. path,
              handler = handler_after(lines, index), framework = "flask", kind = "route", line = index,
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
