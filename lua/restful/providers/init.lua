local M = { registry = {} }

local builtins = {
  "restful.providers.java.spring", "restful.providers.java.jaxrs",
  "restful.providers.python.fastapi", "restful.providers.python.flask", "restful.providers.python.django",
  "restful.providers.go.net_http", "restful.providers.go.gin", "restful.providers.go.chi",
  "restful.providers.node.express", "restful.providers.node.fastify", "restful.providers.node.nest",
}

function M.register(provider)
  assert(type(provider) == "table" and type(provider.id) == "string", "provider.id is required")
  assert(not M.registry[provider.id], "provider is already registered: " .. provider.id)
  M.registry[provider.id] = provider
  for _, alias in ipairs(provider.aliases or {}) do
    assert(not M.registry[alias], "provider alias is already registered: " .. alias)
    M.registry[alias] = provider
  end
  return provider
end
function M.get(id) return M.registry[id] end
function M.list()
  local result, seen = {}, {}
  for _, provider in pairs(M.registry) do
    if not seen[provider] then
      seen[provider] = true
      result[#result + 1] = provider
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end
function M.load(opts)
  opts = opts or {}
  for _, name in ipairs(opts.modules or builtins) do
    local ok, provider = pcall(require, name)
    if ok and type(provider) == "table" then
      if not provider.id then provider.id = name:match("([%w_]+)$") end
      if provider.id then M.register(provider) end
    end
  end
  for _, provider in ipairs(opts.providers or {}) do M.register(provider) end
  return M.list()
end

function M._reset() M.registry = {} end
M.load()
return M
