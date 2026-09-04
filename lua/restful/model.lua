local M = {}

local methods = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true, TRACE = true, ANY = true, ALL = true }
local confidence = { confirmed = true, partial = true, generated = true, conditional = true, ["runtime-confirmed"] = true }
local sources = { declared = true, ["path-derived"] = true, accessed = true, generated = true, runtime = true, unknown = true }

local function location(value)
  if value == nil then return nil end
  if type(value) == "string" then return { file = value, line = 1, column = 1 } end
  if type(value) ~= "table" then return nil end
  local file = value.file or value.path
  if type(file) == "table" then file = file.path or file.name or file.file end
  if type(file) ~= "string" then return nil end
  return { file = file, line = tonumber(value.line) or 1, column = tonumber(value.column) or 1 }
end

function M.join_path(...)
  local result = ""
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    if part ~= nil and tostring(part) ~= "" then result = result .. "/" .. tostring(part) end
  end
  result = result:gsub("//+", "/")
  if result == "" then return "/" end
  return result:sub(1, 1) == "/" and result or "/" .. result
end

function M.parameter(raw)
  raw = raw or {}
  local source = raw.source or "unknown"
  if not sources[source] then source = "unknown" end
  return {
    name = tostring(raw.name or raw.wire_name or "parameter"), wire_name = tostring(raw.wire_name or raw.name or "parameter"),
    location = raw.location or "query", required = raw.required, type = raw.type, example = raw.example,
    source = source, location_ref = location(raw.location_ref),
  }
end

function M.stable_id(endpoint)
  local handler = endpoint.handler or endpoint.declaration or {}
  local pieces = {
    endpoint.kind, endpoint.framework, endpoint.language, table.concat(endpoint.methods or {}, ","), endpoint.path,
    endpoint.service, endpoint.module, handler.file or handler.path, handler.line, handler.column,
  }
  local values = {}
  for index, value in ipairs(pieces) do values[index] = tostring(value or "") end
  local text = table.concat(values, "|")
  local hash = 5381
  for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 2147483647 end
  return string.format("%s:%08x", endpoint.framework or "api", hash)
end

function M.endpoint(raw)
  raw = raw or {}
  local methods_out = raw.methods or (raw.method and { raw.method }) or { "ANY" }
  if type(methods_out) == "string" then methods_out = { methods_out } end
  local normalized = {}
  for _, method in ipairs(methods_out) do
    method = tostring(method):upper()
    if methods[method] then normalized[#normalized + 1] = method end
  end
  if #normalized == 0 then normalized[1] = "ANY" end
  table.sort(normalized)
  local result = {
    kind = raw.kind or "server", framework = raw.framework or raw.provider or "unknown", language = raw.language or "unknown",
    methods = normalized, path = M.join_path(raw.path or "/"), raw_path = raw.raw_path, service = raw.service, module = raw.module,
    handler = location(raw.handler), declaration = location(raw.declaration or raw.handler), parameters = {}, body = raw.body,
    middleware = raw.middleware or {}, provenance = raw.provenance or {}, confidence = confidence[raw.confidence] and raw.confidence or "partial",
    diagnostics = raw.diagnostics or {},
  }
  result.handler_name = raw.handler_name or raw.name
  result.description = raw.description or raw.comment or raw.summary
  for _, parameter in ipairs(raw.parameters or {}) do result.parameters[#result.parameters + 1] = M.parameter(parameter) end
  result.id = raw.id or M.stable_id(result)
  return result
end

function M.compare(a, b)
  local ak, bk = table.concat(a.methods or {}, ",") .. " " .. (a.path or ""), table.concat(b.methods or {}, ",") .. " " .. (b.path or "")
  if ak ~= bk then return ak < bk end
  return (a.id or "") < (b.id or "")
end

function M.location(value) return location(value) end
return M
