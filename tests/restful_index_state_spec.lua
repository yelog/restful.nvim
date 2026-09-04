local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")
local index = assert(loadfile(config_root .. "/lua/restful/index.lua"))()
index._reset()

local first = index.state("/tmp/project-a")
local second = index.state("/tmp/project-b")
assert(first ~= second, "roots must have independent state")
assert(first.status == "idle" and second.status == "idle")
assert(first.generation == 0 and second.generation == 0)

local old_generation = index._begin_generation(first)
local new_generation = index._begin_generation(first)
assert(new_generation > old_generation)

local old_working = { files = {}, endpoints = { { path = "/old", methods = { "GET" }, id = "old" } }, diagnostics = { items = {} } }
local new_working = { files = {}, endpoints = { { path = "/new", methods = { "GET" }, id = "new" } }, diagnostics = { items = {} } }
assert(not index._commit(first, old_generation, old_working), "stale generation must not commit")
assert(index._commit(first, new_generation, new_working), "latest generation should commit")
assert(first.endpoints[1].path == "/new" and first.status == "ready")

print("api-query-index-state-tests: ok")
