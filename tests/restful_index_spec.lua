local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.mkdir(root .. "/target", "p")

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

write(root .. "/src/UsersController.java", {
  "@RestController",
  '@RequestMapping("/api")',
  "class UsersController {",
  '  @GetMapping("/users")',
  "  Object users() {}",
  "}",
})
write(root .. "/src/Ordinary.java", { "class Ordinary {}" })
write(root .. "/target/GeneratedController.java", { "@RestController class GeneratedController {}" })

local index = require("restful.index")
local candidates = index.candidate_files(root, { exclude = { "target" } })
assert(#candidates == 1 and candidates[1]:match("UsersController%.java$"),
  "candidate discovery should skip ordinary source and excluded build output")

local result = index.scan_root(root, { exclude = { "target" }, provider = "spring" })
assert(#result.endpoints == 1, "candidate files should still produce Spring endpoints")
assert(vim.tbl_count(result.files) == 1, "the index should only read candidate source files")

vim.fn.delete(root, "rf")
print("api-query-index-tests: ok")
