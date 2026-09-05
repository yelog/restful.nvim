local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")
local index = assert(loadfile(config_root .. "/lua/restful/index.lua"))()
index._reset()

local root = vim.fn.tempname()
local src = root .. "/src"
vim.fn.mkdir(src, "p")
local first = src .. "/First.java"
local second = src .. "/Second.java"
vim.fn.writefile({ "@RestController", '@RequestMapping("/one")', "class First {", "  /**", "   * @description: First endpoint", "   */", '  @GetMapping("/first")', "  void first() {}", "}" }, first)
vim.fn.writefile({ "@RestController", '@RequestMapping("/two")', "class Second {", '  @GetMapping("/second")', "  void second() {}", "}" }, second)

local state = index.state(root)
index.scan_root(root, { provider = "spring" })
assert(#state.endpoints == 2, "initial file reports should aggregate")
assert(vim.tbl_count(state.files) == 2, "full scan should cache one report per file")

index.refresh_file(first, { root = root, provider = "spring" })
assert(#state.endpoints == 2, "refreshing a fully indexed file must not duplicate endpoints")
assert(vim.tbl_count(state.files) == 2, "refreshing a fully indexed file must replace its report")

vim.fn.writefile({ "@RestController", '@RequestMapping("/one")', "class First {", '  @GetMapping("/updated")', "  void first() {}", "}" }, first)
index.refresh_file(first, { root = root, provider = "spring" })
assert(#state.endpoints == 2, "refreshing one file must preserve other reports")
assert(state.endpoints[1].path == "/two/second" or state.endpoints[2].path == "/two/second", "unchanged file should remain")
assert(state.endpoints[1].path == "/one/updated" or state.endpoints[2].path == "/one/updated", "changed file should be replaced")
for _, endpoint in ipairs(state.endpoints) do
  if endpoint.path == "/one/updated" then
    assert(endpoint.description == nil, "removed description must not survive a file refresh")
    assert(require("restful.picker").display_name(endpoint) == "first", "missing description should display the method name")
  end
end

vim.fn.writefile({ "class First {}" }, first)
index.refresh_file(first, { root = root, provider = "spring" })
assert(#state.endpoints == 1 and state.endpoints[1].path == "/two/second", "removed mapping should remove old endpoint")

vim.fn.delete(root, "rf")
print("api-query-incremental-tests: ok")
