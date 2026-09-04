local M = {}

local function annotation(text, line)
  local name, arguments = text:match("@([%w_$.]+)%s*(%b())")
  name = name or text:match("@([%w_$.]+)")
  return {
    name = name and name:match("([%w_]+)$") or "",
    arguments = arguments,
    text = text,
    line = line,
    column = 1,
  }
end

local function balanced(text)
  local depth = 0
  for character in text:gmatch(".") do
    if character == "(" then depth = depth + 1 elseif character == ")" then depth = depth - 1 end
  end
  return depth <= 0
end

local function method_name(line)
  if line:match("^%s*@") or line:match("^%s*(if|for|while|switch|catch)%s*%(") then return nil end
  local name = line:match("[%w_<>%[%], ?]+%s+([%w_]+)%s*%(")
  if not name or line:match("^%s*(class|interface|record)%s") then return nil end
  return name
end

function M.parse(text)
  local types, pending, lines = {}, {}, vim.split(text or "", "\n", { plain = true })
  local current
  local annotation_text, annotation_line
  for line_number, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if annotation_text then
      annotation_text = annotation_text .. " " .. trimmed
      if balanced(annotation_text) then
        pending[#pending + 1] = annotation(annotation_text, annotation_line)
        annotation_text, annotation_line = nil, nil
      end
    elseif trimmed:match("^@") then
      annotation_text, annotation_line = trimmed, line_number
      if balanced(annotation_text) then
        pending[#pending + 1] = annotation(annotation_text, line_number)
        annotation_text, annotation_line = nil, nil
      end
    else
      local name = trimmed:match("%f[%w]class%s+([%w_]+)")
      local kind = name and "class" or nil
      if not name then name = trimmed:match("%f[%w]interface%s+([%w_]+)"); kind = name and "interface" or nil end
      if not name then name = trimmed:match("%f[%w]record%s+([%w_]+)"); kind = name and "record" or nil end
      if name then
        current = { kind = kind, name = name, line = line_number, annotations = pending, methods = {}, types = {} }
        types[#types + 1], pending = current, {}
      else
        local method = method_name(trimmed)
        if method and current then
          local method_line = line_number
          current.methods[#current.methods + 1] = { name = method, line = method_line, column = (line:find(method, 1, true) or 1), signature = line, annotations = pending }
          pending = {}
        elseif not trimmed:match("^//") and not trimmed:match("^/%*") and not trimmed:match("^import%s") and not trimmed:match("^package%s") then
          pending = {}
        end
      end
    end
  end
  return types
end

return M
