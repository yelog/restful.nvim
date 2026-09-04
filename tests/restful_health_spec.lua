local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

local messages = {}
local previous = vim.health
vim.health = {
  start = function(name) messages[#messages + 1] = { "start", name } end,
  ok = function(message) messages[#messages + 1] = { "ok", message } end,
  error = function(message) messages[#messages + 1] = { "error", message } end,
  info = function(message) messages[#messages + 1] = { "info", message } end,
}

require("restful.health").check()
vim.health = previous

assert(messages[1][1] == "start" and messages[1][2] == "restful.nvim")
assert(#messages >= 4, "health check should report all runtime dependencies")
print("restful-health-tests: ok")
