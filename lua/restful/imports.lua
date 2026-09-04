local M = {}
function M.parse(text)
  local result = { imports = {}, exports = {} }
  for line in (text or ""):gmatch("[^\n]*") do
    local name, source = line:match([[import%s+.-from%s+['"]([^'"]+)['"]])
    if not name then source = line:match([[require%s*%(%s*['"]([^'"]+)['"]%s*%)]]); name = source end
    if source then result.imports[#result.imports + 1] = { name = name, source = source } end
    local exported = line:match([[export%s+(?:default%s+)?[%w_]*%s*([%w_]+)]])
    if exported then result.exports[#result.exports + 1] = exported end
  end
  return result
end
return M
