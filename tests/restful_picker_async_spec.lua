local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")

local picker = assert(loadfile(config_root .. "/lua/restful/picker.lua"))()
local captured
local previous = _G.Snacks
_G.Snacks = { picker = { pick = function(opts) captured = opts; return opts end } }

local finder = function() return {} end
picker.open(finder, { title = "API Query" })
assert(type(captured.finder) == "function" and captured.finder ~= finder, "async source must be wrapped as a Snacks finder")
assert(captured.items == nil, "async source must not be materialized before opening")
assert(captured.show_delay == 0 and captured.show_empty == true, "cold picker should open immediately")

picker.open(finder, { query = "users", picker = { keys = { open = "<a-o>" } } })
assert(captured.pattern == "users", "picker should preserve the initial query")
assert(captured.win.input.keys["<a-o>"], "nested picker key configuration should be honored")

local wrapped = captured.finder({}, {})
assert(type(wrapped) == "table", "ready finder sources should return items")

picker.open(function()
  return function(cb) cb({ path = "/streamed", methods = { "GET" } }) end
end, {})
local stream = captured.finder({}, {})
local streamed
stream(function(item) streamed = item end)
assert(streamed and streamed.text:find("/streamed", 1, true), "streamed endpoints must be picker items")

captured = nil
picker.open({ { path = "/users", methods = { "GET" } } }, {})
assert(captured.items and #captured.items == 1, "ready arrays must remain supported")

_G.Snacks = previous
print("api-query-picker-async-tests: ok")
