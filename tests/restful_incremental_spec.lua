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
vim.fn.writefile({ "@RestController", '@RequestMapping("/one")', "class First {", '  @GetMapping("/first")', "  void first() {}", "}" }, first)
vim.fn.writefile({ "@RestController", '@RequestMapping("/two")', "class Second {", '  @GetMapping("/second")', "  void second() {}", "}" }, second)

local state = index.state(root)
index.refresh_file(first, { root = root, provider = "spring" })
index.refresh_file(second, { root = root, provider = "spring" })
assert(#state.endpoints == 2, "initial file reports should aggregate")

vim.fn.writefile({ "@RestController", '@RequestMapping("/one")', "class First {", '  @GetMapping("/updated")', "  void first() {}", "}" }, first)
index.refresh_file(first, { root = root, provider = "spring" })
assert(#state.endpoints == 2, "refreshing one file must preserve other reports")
assert(state.endpoints[1].path == "/two/second" or state.endpoints[2].path == "/two/second", "unchanged file should remain")
assert(state.endpoints[1].path == "/one/updated" or state.endpoints[2].path == "/one/updated", "changed file should be replaced")

vim.fn.writefile({ "class First {}" }, first)
index.refresh_file(first, { root = root, provider = "spring" })
assert(#state.endpoints == 1 and state.endpoints[1].path == "/two/second", "removed mapping should remove old endpoint")

vim.fn.delete(root, "rf")
print("api-query-incremental-tests: ok")
