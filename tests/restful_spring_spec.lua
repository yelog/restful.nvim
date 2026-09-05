local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")

local spring = require("restful.providers.java.spring")
local picker = require("restful.picker")

local function find_endpoint(items, method, path)
  for _, item in ipairs(items) do
    if item.path == path and vim.tbl_contains(item.methods or {}, method) then return item end
  end
end

local function assert_absent(items, path)
  for _, item in ipairs(items) do assert(item.path ~= path, "unexpected endpoint: " .. path) end
end

local function extract_client(javadoc)
  local source = table.concat({
    "public interface SysMenuClient {",
    javadoc,
    '@RequestMapping("/findByMenuType")',
    "ResultData<List<SysMenu>> findByMenuType(@RequestParam(\"menuType\") String menuType);",
    "}",
  }, "\n")
  return spring.extract({
    source = source,
    declaration_parser = function() return nil, "Java parser unavailable" end,
  }, { path = "/tmp/SysMenuClient.java" })[1]
end

local tagged_client = extract_client(table.concat({
  "/**",
  " * @param menuType 菜单类型",
  " * @param menuNameList 菜单名称集合",
  " * @description: 根据菜单类型和菜单的名称获取相关配置",
  " * @return: util.com.lenovo.moss.framework.core.ResultData",
  " * @author: hezhiqin",
  " * @time: 2022/6/25 21:10",
  " */",
}, "\n"))
assert(tagged_client.description == "根据菜单类型和菜单的名称获取相关配置", "@description should be used as the endpoint name")
assert(picker.display_name(tagged_client) == tagged_client.description, "picker should display the Javadoc description")
assert(tagged_client.path == "/findByMenuType", "Javadoc parsing must not change the route")
assert(vim.tbl_contains(tagged_client.methods, "ANY"), "RequestMapping should retain the HTTP method")

local metadata_only_client = extract_client(table.concat({
  "/**",
  " * @param menuType 菜单类型",
  " * @return: util.com.lenovo.moss.framework.core.ResultData",
  " */",
}, "\n"))
assert(metadata_only_client.description == nil, "metadata-only Javadoc should not become a description")
assert(picker.display_name(metadata_only_client) == "findByMenuType", "missing description should fall back to the method name")

local prose_client = extract_client(table.concat({
  "/**",
  " * 根据菜单类型查询菜单。",
  " * 该接口支持批量名称过滤。",
  " *",
  " * @param menuType 菜单类型",
  " * @return 菜单结果",
  " */",
}, "\n"))
assert(prose_client.description == "根据菜单类型查询菜单。 该接口支持批量名称过滤。", "Javadoc prose should use its first paragraph")

local multiline_description = extract_client(table.concat({
  "/**",
  " * @description: 根据菜单类型查询菜单。",
  " * 支持批量名称过滤。",
  " * @return 菜单结果",
  " */",
}, "\n"))
assert(multiline_description.description == "根据菜单类型查询菜单。 支持批量名称过滤。", "description tags should include continuation text")

local description_without_colon = extract_client(table.concat({
  "/**",
  " * @description 根据菜单类型查询菜单。",
  " * 支持批量名称过滤。",
  " * @return 菜单结果",
  " */",
}, "\n"))
assert(description_without_colon.description == "根据菜单类型查询菜单。 支持批量名称过滤。", "description without a colon should be supported")

local annotated_client = spring.extract({
  source = table.concat({
    "public interface SysMenuClient {",
    "/**",
    " * Javadoc description",
    " */",
    '@Operation(summary = "Operation summary")',
    '@RequestMapping("/findByMenuType")',
    "ResultData<List<SysMenu>> findByMenuType();",
    "}",
  }, "\n"),
  declaration_parser = function() return nil, "Java parser unavailable" end,
}, { path = "/tmp/SysMenuClient.java" })[1]
assert(annotated_client.description == "Operation summary", "operation annotations should take priority")

local adjacent_client = spring.extract({
  source = table.concat({
    "public interface SysMenuClient {",
    "/** first method */",
    '@RequestMapping("/first")',
    "ResultData first();",
    "/** second method */",
    '@RequestMapping("/second")',
    "ResultData second();",
    "}",
  }, "\n"),
  declaration_parser = function() return nil, "Java parser unavailable" end,
}, { path = "/tmp/SysMenuClient.java" })
assert(#adjacent_client == 2, "adjacent mapped methods should both be extracted")
assert(adjacent_client[1].description == "first method", "the first Javadoc must stay with its method")
assert(adjacent_client[2].description == "second method", "the second Javadoc must stay with its method")

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
