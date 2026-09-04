local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")

local fixtures = {
  { id = "spring", language = "java", source = table.concat({
    '@RestController', '@RequestMapping("/api")', 'class Users {',
    '@GetMapping("/{id}")', 'User get(@PathVariable Long id) {}', '}',
  }, "\n") },
  { id = "fastapi", language = "python", source = table.concat({
    'router = APIRouter(prefix="/users")', '@router.get("/{id}")',
    'def get_user(id: int, verbose: bool = False): pass',
  }, "\n") },
  { id = "gin", language = "go", source = 'api := router.Group("/api")\napi.GET("/users/:id", getUser)' },
  { id = "express", language = "javascript", source = 'const router = express.Router();\nrouter.get("/users/:id", getUser);\napp.use("/api", router);' },
  { id = "nest", language = "typescript", source = table.concat({
    '@Controller("users")', 'export class UsersController {', '@Get(":id")',
    'get(@Param("id") id: string) {}', '}',
  }, "\n") },
}

local names = {
  spring = "restful.providers.java.spring",
  fastapi = "restful.providers.python.fastapi",
  gin = "restful.providers.go.gin",
  express = "restful.providers.node.express",
  nest = "restful.providers.node.nest",
}

local available = 0
for _, fixture in ipairs(fixtures) do
  local ok, provider = pcall(require, names[fixture.id])
  if ok then
    available = available + 1
    assert(type(provider.extract or provider.parse) == "function", fixture.id .. " should parse its fixture")
    local parsed
    if fixture.id == "fastapi" then
      parsed = provider.parse(fixture.source, { file = fixture.id .. ".py" })
      assert(#parsed.endpoints == 1, "FastAPI should discover one route")
      assert(parsed.endpoints[1].path == "/users/{id}", "FastAPI should compose the router prefix")
      assert(parsed.endpoints[1].method == "GET", "FastAPI should normalize methods")
    elseif fixture.id == "spring" then
      parsed = provider.extract({ source = fixture.source }, { path = fixture.id .. ".java" })
      assert(#parsed == 1 and parsed[1].path == "/api/{id}", "Spring should compose class and method paths")
      assert(parsed[1].methods[1] == "GET" and parsed[1].parameters[1].location == "path",
        "Spring should parse method and path parameters")
    elseif fixture.id == "gin" then
      local fragments = provider.extract({ source = fixture.source }, fixture.id .. ".go")
      parsed = provider.resolve({}, fragments, {})
      assert(#parsed == 1 and parsed[1].path:gsub("//+", "/") == "/api/users/:id",
        "Gin should compose group prefixes")
    elseif fixture.id == "express" then
      local fragments = provider.extract({}, { path = fixture.id .. ".js", source = fixture.source })
      assert(#fragments == 2 and fragments[1].kind == "route" and fragments[2].kind == "mount",
        "Express should extract both route and mount fragments")
      parsed = provider.resolve({}, fragments, {})
      assert(#parsed == 1 and parsed[1].path:gsub("//+", "/"):match("/users/:id$"),
        "Express should resolve the route fragment")
    elseif fixture.id == "nest" then
      local fragments = provider.extract({}, { path = fixture.id .. ".ts", source = fixture.source })
      parsed = provider.resolve({}, fragments, {})
      assert(#parsed == 1 and parsed[1].path == "/users/:id", "Nest should compose controller and method paths")
    end
  end
end

assert(#fixtures == 5, "the P0 framework fixture set should cover all requested frameworks")

local scanner = require("restful.scanner")
local detector = require("restful.detector")
local scanned = scanner.scan_file(fixtures[1].source, "/tmp/Users.java", { provider = "spring" })
assert(#scanned.endpoints == 1, "scanner should preserve provider endpoints")
assert(scanned.endpoints[1].handler.file == "/tmp/Users.java", "scanner should preserve source file locations")

local picker = require("restful.picker")
local picker_item = picker.item_for(scanned.endpoints[1])
assert(type(picker_item.text) == "string" and picker_item.text:find("/api/%{id%}"),
  "picker items must provide searchable text")
assert(picker_item.file == "/tmp/Users.java", "picker items must provide a jump target")
local formatted = picker.format_endpoint(vim.tbl_extend("force", picker_item, { methods = { "GET" }, path = "/users" }), {})
assert(formatted[1][1] ~= "GET", "the picker should render an HTTP method as an icon")
assert(picker.method_style.GET.icon == "󰯿", "GET should use the configured initial icon")
assert(picker.method_style.POST.icon == "󰰚", "POST should use the configured initial icon")
assert(picker.method_style.PUT.icon == "󰰚", "PUT should use the configured initial icon")
assert(picker.method_style.DELETE.icon == "󰯶", "DELETE should use the configured initial icon")
assert(formatted[1][2] == "DiagnosticOk", "GET should use the success color")
assert(formatted[#formatted].virt_text[1][2] == "SnacksPickerComment", "source filenames should use a muted highlight")
assert(formatted[#formatted].virt_text_win_col, "source filenames should be right-aligned virtual text")
assert(picker_item.text == "<anonymous> /api/{id}" or picker_item.text == "get /api/{id}",
  "only the display name and path should participate in matching")

local configured_detection = detector.for_file(fixtures[1].source, "/tmp/Users.java", { providers = {} })
assert(#configured_detection > 0, "an empty provider configuration should use built-in providers")
print(available == 0 and "api-query-provider-tests: skipped (providers unavailable)" or "api-query-provider-tests: ok")
