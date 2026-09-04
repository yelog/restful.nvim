local M = {}

local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
function M.evaluate(expression, env, depth)
  depth = depth or 0
  if depth > 8 then return { unresolved = true, evidence = "depth limit" } end
  local value = trim(expression)
  local quote = value:match([[^(['"])(.*)%1$]])
  if quote then return { value = value:sub(2, -2), evidence = "literal" } end
  local template = value:match("^`(.-)`$")
  if template and not template:find("${", 1, true) then return { value = template, evidence = "literal" } end
  if env and env[value] ~= nil then return M.evaluate(env[value], env, depth + 1) end
  local parts = {}
  for part in value:gmatch("[^+]+") do parts[#parts + 1] = M.evaluate(part, env, depth + 1) end
  if #parts > 1 then
    local result = ""
    for _, part in ipairs(parts) do if part.unresolved then return { unresolved = true, evidence = value } end; result = result .. tostring(part.value) end
    return { value = result, evidence = "concatenation" }
  end
  return { unresolved = true, evidence = value }
end
return M
