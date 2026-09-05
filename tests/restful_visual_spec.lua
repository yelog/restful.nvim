local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local captured
package.loaded["restful.index"] = { finder = function() return {} end }
package.loaded["restful.picker"] = { open = function(_, opts) captured = opts.query end }
local restful = require("restful")
vim.o.selection = "inclusive"
local function escape()
  vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes("<Esc>", true, false, true) }, bang = true })
end
local function check(lines, keys, expected, opts)
  escape()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes(keys, true, false, true) }, bang = true })
  local registers = { vim.fn.getreg('"'), vim.fn.getreg("0") }
  restful.open(opts)
  assert(captured == expected, vim.inspect({ expected = expected, actual = captured, keys = keys }))
  assert(vim.deep_equal(registers, { vim.fn.getreg('"'), vim.fn.getreg("0") }), "selection must not change registers")
end

check({ "findByMenuType extra" }, "v13l", "findByMenuType")
check({ "abcdef" }, "3lv2h", "bcd")
check({ "菜单类型" }, "vl", "菜单")
check({ "  first", "second  " }, "Vj", "first second")
check({ "abcd", "efgh" }, "<C-v>jl", "ab ef")
vim.o.selection = "exclusive"
check({ "abcdef" }, "v3l", "abc")
vim.o.selection = "inclusive"
local opts = { query = "explicit" }
check({ "abcdef" }, "vl", "explicit", opts)
check({ "abcdef" }, "vl", "", { query = "" })
check({ "abcdef" }, "vl", "ab", {})
escape()
restful.open()
assert(captured == nil, "normal mode must not reuse the previous selection")
print("restful-visual-tests: ok")
