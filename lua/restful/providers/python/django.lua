-- parse(text, opts) -> { endpoints = endpoint[], fragments = fragment[] }
-- parse_text(text, opts), extract(text, opts) -> same result

local M = { id = "django", languages = { "python" }, framework = "django" }

local function strings(value)
  local result = {}
  for quote, text in (value or ""):gmatch([[(["'])(.-)%1]]) do result[#result + 1] = text end
  return result
end

local function first_string(value)
  return strings(value)[1]
end

local function handler_value(value)
  local quoted = first_string(value)
  if quoted then return quoted end
  return (value or ""):match("^%s*([%w_%.]+)") or ""
end

function M.parse(text, opts)
  local output, lines = { endpoints = {}, fragments = {} }, {}
  for line in (text or ""):gmatch("[^\n]*") do lines[#lines + 1] = line end
  for index, line in ipairs(lines) do
    for call, args in line:gmatch([[([%w_]+)%s*%(([^)]*)]]) do
      if call == "path" or call == "re_path" then
      local values = strings(args)
      local route = values[1]
      if route then
        local target = handler_value(args:match([[^[^,]+,%s*(.*)$]]))
        if args:match([[include%s*%(%s*]]) then
          output.fragments[#output.fragments + 1] = { kind = "include", route = route, target = target, regex = call == "re_path", line = index }
        else
          output.endpoints[#output.endpoints + 1] = {
            method = "ANY", path = route, handler = target,
            framework = "django", kind = call, regex = call == "re_path", line = index,
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
