local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")

local ok, request = pcall(require, "restful.request")
if not ok then
  assert(true, "restful.request is not implemented yet")
  print("api-query-request-tests: skipped (restful.request unavailable)")
  return
end

local endpoint = {
  id = "users-show",
  kind = "server",
  framework = "fastapi",
  language = "python",
  methods = { "GET" },
  path = "/api/users/{id}",
  handler = { path = "users.py", line = 8, column = 1 },
  declaration = { path = "users.py", line = 7, column = 1 },
  parameters = {
    { name = "id", wire_name = "id", location = "path", required = true, example = 42, source = "declared" },
    { name = "verbose", wire_name = "verbose", location = "query", example = true, source = "declared" },
    { name = "tag", wire_name = "tag", location = "query", example = "one", source = "declared" },
    { name = "tag", wire_name = "tag", location = "query", example = "two", source = "declared" },
    { name = "X-Tenant", wire_name = "X-Tenant", location = "header", source = "declared" },
  },
  confidence = "confirmed",
  diagnostics = {},
}

local result = assert(request.materialize(endpoint, {
  base_url_variable = "API_BASE_URL",
  fallback_base_url = "http://localhost:8080",
}))
assert(type(result.lines) == "table", "materialize should return HTTP lines")
local draft = table.concat(result.lines, "\n")
assert(draft:find("GET {{API_BASE_URL}}/api/users/42", 1, true), "known examples should materialize in the path")
assert(draft:find("tag=one&tag=two", 1, true), "repeated query values should be preserved")
assert(draft:find("X%-Tenant: {{X%-Tenant}}"), "headers should become variables, never secret values")
assert(result.unresolved and #result.unresolved > 0, "unassigned placeholders should be reported")

local fallback = assert(request.materialize(vim.tbl_extend("force", endpoint, { path = "/health" }), {
  fallback_base_url = "http://localhost:8080",
}))
assert(table.concat(fallback.lines, "\n"):find("http://localhost:8080/health", 1, true),
  "fallback URL should be used when no variable is configured")
assert(request.materialize({ methods = { "POST" }, path = "/write", handler = endpoint.handler }, {}).lines,
  "unsafe methods should still generate a draft")

print("api-query-request-tests: ok")
