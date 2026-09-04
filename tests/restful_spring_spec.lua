local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")

local spring = require("restful.providers.java.spring")

local function find_endpoint(items, method, path)
  for _, item in ipairs(items) do
    if item.path == path and vim.tbl_contains(item.methods or {}, method) then return item end
  end
end

local function assert_absent(items, path)
  for _, item in ipairs(items) do assert(item.path ~= path, "unexpected endpoint: " .. path) end
end

local agreement_source = table.concat({
  "@RestController",
  '@RequestMapping("/agreement")',
  '@Tag(name = "agreement")',
  "public class AgreementController {",
  '@Operation(summary = "page")',
  '@PostMapping("/page")',
  '@PreAuthorize("hasAuthority(\'agreement\')")',
  "public ResultData<?> page(@RequestBody Query query) {}",
  "",
  "@PostMapping",
  "@CacheEvict(allEntries = true)",
  "public ResultData<?> create(@RequestBody Create body) {}",
  "}",
}, "\n")

local agreement = spring.extract({ source = agreement_source }, { path = "/tmp/AgreementController.java" })
assert(#agreement == 2, "class mapping and ordinary annotations must not create endpoints")
assert(find_endpoint(agreement, "POST", "/agreement/page"), "method path should include controller prefix")
local create = assert(find_endpoint(agreement, "POST", "/agreement"))
assert_absent(agreement, "/page")
assert_absent(agreement, "/")
assert(create.declaration.line == 10, "declaration should point to the method mapping")
assert(create.handler.line == 12, "handler should point to the Java method")

local client_source = table.concat({
  "@RestController",
  '@RequestMapping("/client")',
  '@PreAuthorize("hasAuthority(\'client\')")',
  "public class ClientController {",
  '@RequestMapping("/delete")',
  "public ResultData<?> delete(String clientId) {}",
  "",
  '@PostMapping("/batchUpdClientVer")',
  "public ResultData<?> batchUpdate(@RequestBody Request request) {}",
  "}",
}, "\n")

local client = spring.extract({ source = client_source }, { path = "/tmp/ClientController.java" })
assert(#client == 2, "only mapped methods should create endpoints")
local delete = assert(find_endpoint(client, "ANY", "/client/delete"))
assert(find_endpoint(client, "POST", "/client/batchUpdClientVer"))
assert_absent(client, "/client")
assert_absent(client, "/delete")
assert(delete.declaration.line == 5, "delete declaration should point to its mapping")
assert(delete.handler.line == 6, "delete handler should point to the Java method")

local fallback_client = spring.extract({
  source = client_source,
  declaration_parser = function() return nil, "Java parser unavailable" end,
}, { path = "/tmp/ClientController.java" })
assert(find_endpoint(fallback_client, "ANY", "/client/delete"), "fallback should retain controller prefixes")
assert_absent(fallback_client, "/client")
assert_absent(fallback_client, "/delete")

local multi_source = table.concat({
  '@RequestMapping({"/v1", "/v2"})',
  "class UsersController {",
  '@RequestMapping(path = {"/users", "/members"}, method = {RequestMethod.GET, RequestMethod.HEAD})',
  "User get(String id) {}",
  "User helper() {}",
  "}",
  '@RequestMapping("/admin")',
  "class AdminController {",
  '@PostMapping("/create")',
  "void create() {}",
  "}",
}, "\n")
local multi = spring.extract({ source = multi_source }, { path = "/tmp/Multi.java" })
assert(#multi == 5, "class and method paths should produce one endpoint per path with all methods")
assert(find_endpoint(multi, "GET", "/v1/users"), "first controller prefix should remain local")
assert(find_endpoint(multi, "HEAD", "/v2/members"), "all method/path combinations should be preserved")
assert(find_endpoint(multi, "POST", "/admin/create"), "second controller should use its own prefix")
assert_absent(multi, "/v1")
assert_absent(multi, "/users")

local no_route = spring.extract({ source = '@RequestMapping("/only-prefix")\nclass PrefixOnly {}' }, { path = "/tmp/PrefixOnly.java" })
assert(#no_route == 0, "a controller mapping without a mapped method is not an endpoint")

local non_routes = spring.extract({ source = table.concat({
  "class Helpers {",
  "  Helpers() {}",
  "  Object helper() { return call(); }",
  "  Object call() { return null; }",
  "}",
}, "\n") }, { path = "/tmp/Helpers.java" })
assert(#non_routes == 0, "constructors and ordinary methods are not endpoints")

print("api-query-spring-tests: ok")
