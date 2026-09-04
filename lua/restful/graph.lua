local M = {}
function M.compose(fragments, opts)
  opts = opts or {}; local mounts, endpoints, diagnostics = {}, {}, {}
  for _, fragment in ipairs(fragments or {}) do
    if fragment.kind == "mount" or fragment.kind == "include" then
      local child = fragment.receiver or fragment.router or fragment.blueprint or fragment.target
      mounts[child] = mounts[child] or {}; mounts[child][#mounts[child] + 1] = fragment
    end
  end
  local function prefixes(name, prefix, seen)
    if seen[name] then diagnostics[#diagnostics + 1] = { message = "route composition cycle: " .. tostring(name), severity = "warn" }; return {} end
    seen[name] = true; local parents = mounts[name]
    if not parents then seen[name] = nil; return { prefix } end
    local result = {}
    for _, mount in ipairs(parents) do for _, value in ipairs(prefixes(mount.parent, (mount.path or mount.prefix or "") .. prefix, seen)) do result[#result + 1] = value end end
    seen[name] = nil; return result
  end
  for _, fragment in ipairs(fragments or {}) do
    if fragment.kind == "route" and fragment.path then
      for _, prefix in ipairs(prefixes(fragment.receiver or fragment.router or "", "", {})) do
        local copy = {}; for key, value in pairs(fragment) do copy[key] = value end
        copy.path = (prefix .. "/" .. fragment.path):gsub("//+", "/"); copy.kind = "server"; endpoints[#endpoints + 1] = copy
      end
    end
  end
  return endpoints, diagnostics
end
return M
