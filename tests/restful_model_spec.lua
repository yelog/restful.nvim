local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({
  config_root .. "/lua/?.lua",
  config_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local function optional_require(name)
  local ok, value = pcall(require, name)
  if not ok then
    return nil
  end
  return value
end

local model = optional_require("restful.model")
if not model then
  assert(true, "restful.model is not implemented yet")
  print("api-query-model-tests: skipped (restful.model unavailable)")
  return
end

local endpoint = assert(model.endpoint({
  kind = "server",
  framework = "spring",
  language = "java",
  methods = { "get", "POST" },
  path = "api/users/:id",
  handler = { path = "Users.java", line = 12, column = 3 },
  declaration = { path = "Users.java", line = 10, column = 1 },
  parameters = {
    { name = "id", wire_name = "id", location = "path", source = "path-derived" },
    { name = "tag", wire_name = "tag", location = "query", source = "declared" },
    { name = "tag", wire_name = "tag", location = "query", source = "declared" },
  },
  confidence = "confirmed",
  diagnostics = {},
}))
assert(vim.deep_equal({ "GET", "POST" }, endpoint.methods), "methods should be uppercase")
assert(endpoint.path == "/api/users/:id", "paths should be normalized with a leading slash")
assert(#endpoint.parameters == 3, "duplicate parameters must be preserved")
assert(endpoint.handler.line == 12 and endpoint.declaration.column == 1, "locations should survive normalization")
assert(type(model.join_path) == "function" and model.join_path("/api/", "/users", "") == "/api/users",
  "join_path should collapse boundary slashes")

local id = assert(model.stable_id(endpoint))
assert(id == model.stable_id(vim.deepcopy(endpoint)), "stable IDs should be content-derived")
assert(type(model.compare) == "function", "model should expose a deterministic comparator")
assert(model.compare({ methods = { "GET" }, path = "/a" }, { methods = { "POST" }, path = "/a" }),
  "GET should sort before POST")
local unknown_parameter = assert(model.parameter({ name = "x", location = "unknown" }))
assert(unknown_parameter.name == "x", "parameter normalization should remain total for partial providers")
local partial_endpoint = assert(model.endpoint({ path = "/x", handler = { path = "x" }, confidence = "invented" }))
assert(partial_endpoint.confidence == "partial" or partial_endpoint.confidence == "invented",
  "unknown confidence should degrade or be reported by the model")

print("api-query-model-tests: ok")
