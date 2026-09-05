local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(test_file))
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")
package.loaded["restful.index"] = nil
local index = assert(loadfile(config_root .. "/lua/restful/index.lua"))()

index._reset()
local finder_state = index.state("/tmp/finder-root")
local original_discover, original_parse = index.discover, index.parse_candidates
local streamed, resumed = {}, 0
index.discover = function(_, opts)
  opts.on_done({ "/tmp/finder.java" })
  return { cancel = function() end }
end
index.parse_candidates = function(_, opts)
  opts.on_item({ id = "finder", path = "/finder", methods = { "GET" } })
  opts.on_done(nil, {
    files = {},
    endpoints = { { id = "finder", path = "/finder", methods = { "GET" } } },
    diagnostics = { items = {} },
  })
  return { cancel = function() end }
end
local finder = index.finder({ root = "/tmp/finder-root", force = true })
assert(type(finder) == "function", "cold roots should expose an async finder")
finder({}, { async = {
  on = function() end,
  resume = function() resumed = resumed + 1 end,
  suspend = function() error("synchronous fake finder should not suspend") end,
} })(function(item) streamed[#streamed + 1] = item end)
assert(#streamed == 1 and streamed[1].path == "/finder", "cold finder should stream parsed endpoints")
assert(resumed == 1 and finder_state.status == "ready", "cold finder should commit after parsing")
index.discover, index.parse_candidates = original_discover, original_parse

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local completed
local killed = false
local discovery_callback
local process = index.discover(root, {
  system = function(command, opts, callback)
    assert(command[1] == "rg" and opts.cwd == vim.loop.fs_realpath(root))
    discovery_callback = callback
    return { kill = function() killed = true end, callback = callback }
  end,
  on_done = function(paths, err) completed = { paths = paths, err = err } end,
})
process.cancel()
assert(killed, "discovery cancellation must terminate rg")
discovery_callback({ code = 0, stdout = "src/A.java\nsrc/B.java\n", stderr = "" })
assert(not completed, "cancelled discovery must ignore late completion")

local scheduled = {}
local parsed, done
local reports = {
  ["/tmp/a"] = { endpoints = { { id = "a", path = "/a", methods = { "GET" } } }, diagnostics = { items = {} } },
  ["/tmp/b"] = { endpoints = { { id = "b", path = "/b", methods = { "GET" } } }, diagnostics = { items = {} } },
  ["/tmp/c"] = { endpoints = { { id = "a", path = "/duplicate", methods = { "GET" } } }, diagnostics = { items = {} } },
}
index.parse_candidates({ "/tmp/a", "/tmp/b", "/tmp/c" }, {
  parse_budget_ms = 1,
  now = (function()
    local value = 0
    return function() value = value + 2e6; return value end
  end)(),
  schedule = function(fn) scheduled[#scheduled + 1] = fn end,
  scan_path = function(path) return reports[path] or reports[path:gsub("^/private", "")] end,
  on_item = function(endpoint) parsed = parsed or {}; parsed[#parsed + 1] = endpoint end,
  on_done = function(err, value) done = { err = err, value = value } end,
})
assert(#scheduled == 1, "parsing should yield after the time budget")
while #scheduled > 0 do
  local step = table.remove(scheduled, 1)
  step()
end
assert(#parsed == 2, "duplicate endpoint IDs should be streamed only once")
assert(done and not done.err and #done.value.endpoints == 2, "parsing should commit a complete working set")

local alias_calls, alias_done
index.parse_candidates({ "/tmp/a", "/private/tmp/a" }, {
  scan_path = function(path)
    alias_calls = (alias_calls or 0) + 1
    return reports[path:gsub("^/private", "")]
  end,
  on_done = function(err, value) alias_done = { err = err, value = value } end,
})
vim.wait(1000, function() return alias_done ~= nil end)
assert(alias_calls == 1, "path aliases should scan one file only once")
assert(alias_done and not alias_done.err and vim.tbl_count(alias_done.value.files) == 1,
  "path aliases should produce one file report")

local refresh_discover, refresh_parse = index.discover, index.parse_candidates
local refresh_root = vim.fn.tempname()
local refresh_file = refresh_root .. "/Changed.java"
vim.fn.mkdir(refresh_root, "p")
vim.fn.writefile({ "class Changed {}" }, refresh_file)
local refresh_state = index.state(refresh_root)
local refresh_key = vim.fs.joinpath(vim.loop.fs_realpath(refresh_root), "Changed.java")
local refresh_calls = 0
index.discover = function(_, opts)
  opts.on_done({ refresh_file })
  return { cancel = function() end }
end
index.parse_candidates = function(_, opts)
  refresh_calls = refresh_calls + 1
  if refresh_calls == 1 then
    index.invalidate(refresh_file, { root = refresh_root, debounce_ms = 100000 })
    opts.on_done(nil, {
      files = { [refresh_key] = { endpoints = { { id = "old", path = "/old", methods = { "GET" } } }, diagnostics = { items = {} } } },
      endpoints = { { id = "old", path = "/old", methods = { "GET" } } },
      diagnostics = { items = {} },
    })
  elseif refresh_calls == 2 then
    index.invalidate(refresh_file, { root = refresh_root, debounce_ms = 100000 })
    opts.on_done(nil, {
      files = { [refresh_key] = { endpoints = { { id = "new", path = "/new", methods = { "GET" } } }, diagnostics = { items = {} } } },
      endpoints = { { id = "new", path = "/new", methods = { "GET" } } },
      diagnostics = { items = {} },
    })
  else
    opts.on_done(nil, {
      files = { [refresh_key] = { endpoints = { { id = "latest", path = "/latest", methods = { "GET" } } }, diagnostics = { items = {} } } },
      endpoints = { { id = "latest", path = "/latest", methods = { "GET" } } },
      diagnostics = { items = {} },
    })
  end
  return { cancel = function() end }
end
index.refresh({ root = refresh_root, force = true })
assert(refresh_calls == 3, "refresh should rescan each change during the full scan")
assert(refresh_state.endpoints[1].path == "/latest", "latest file content must win over an older full-scan result")
index.discover, index.parse_candidates = refresh_discover, refresh_parse
index._reset()

local delete_root = vim.fn.tempname()
local delete_path = delete_root .. "/Deleted.java"
vim.fn.mkdir(delete_root, "p")
vim.fn.writefile({ "class Deleted {}" }, delete_path)
local delete_state = index.state(delete_root)
local delete_key = vim.fs.joinpath(vim.loop.fs_realpath(delete_root), "Deleted.java")
local delete_discover, delete_parse = index.discover, index.parse_candidates
local delete_calls = 0
index.discover = function(_, opts)
  opts.on_done({ delete_path })
  return { cancel = function() end }
end
index.parse_candidates = function(_, opts)
  delete_calls = delete_calls + 1
  if delete_calls == 1 then
    vim.fn.delete(delete_path)
    index.invalidate(delete_path, { root = delete_root, debounce_ms = 100000 })
    opts.on_done(nil, {
      files = { [delete_key] = { endpoints = { { id = "deleted", path = "/deleted", methods = { "GET" } } }, diagnostics = { items = {} } } },
      endpoints = { { id = "deleted", path = "/deleted", methods = { "GET" } } },
      diagnostics = { items = {} },
    })
  else
    opts.on_done(nil, { files = {}, endpoints = {}, diagnostics = { items = {} } })
  end
  return { cancel = function() end }
end
index.refresh({ root = delete_root, force = true })
assert(#delete_state.endpoints == 0, "deleting a dirty file must remove its old report before commit")
index.discover, index.parse_candidates = delete_discover, delete_parse
index._reset()

vim.fn.delete(root, "rf")
vim.fn.delete(refresh_root, "rf")
vim.fn.delete(delete_root, "rf")
print("api-query-async-tests: ok")
