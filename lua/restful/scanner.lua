local model = require("restful.model")
local detector = require("restful.detector")
local graph = require("restful.graph")
local diagnostics = require("restful.diagnostics")
local M = {}
local function merge(left, right)
  local result = {}; for key, value in pairs(left or {}) do result[key] = value end; for key, value in pairs(right or {}) do result[key] = value end; return result
end
function M.scan_file(text, path, opts)
  opts = opts or {}; local report = { endpoints = {}, fragments = {}, diagnostics = diagnostics.new(), path = path }
  local selected = opts.provider and { provider = opts.provider } or {}
  local detections = detector.for_file(text, path, merge(opts, selected))
  for _, detection in ipairs(detections) do
    local provider = type(detection.provider) == "table" and detection.provider or require("restful.providers").get(detection.provider)
    if provider then
      local ok, parsed = pcall(function()
        local context = merge(opts, detection)
        context.text = text
        context.source = text
        context.file = path
        if provider.parse then return provider.parse(text, context) end
        return provider.extract(context, { path = path, source = text, text = text }, nil)
      end)
      if ok and parsed then
        local fragments = parsed.fragments or (parsed.endpoints and {}) or parsed
        for _, fragment in ipairs(fragments or {}) do report.fragments[#report.fragments + 1] = fragment end
        local resolved = parsed.endpoints
        if not resolved or #resolved == 0 then
          resolved = provider.resolve and provider.resolve(merge(opts, detection), fragments, graph) or graph.compose(fragments)
        end
        for _, endpoint in ipairs(resolved or {}) do
          endpoint.framework = endpoint.framework or detection.framework or provider.id
          endpoint.language = endpoint.language or detection.language
          endpoint.declaration = endpoint.declaration or endpoint.handler
          if type(endpoint.handler) == "string" then
            endpoint.handler_name = endpoint.handler_name or endpoint.handler
            endpoint.handler = { file = path, line = endpoint.handler_line or endpoint.line or 1, column = 1 }
          end
          if endpoint.handler and endpoint.handler.file == nil and type(endpoint.handler.path) == "string" then
            endpoint.handler.file = endpoint.handler.path
          end
          if endpoint.declaration and endpoint.declaration.file == nil and type(endpoint.declaration.path) == "string" then
            endpoint.declaration.file = endpoint.declaration.path
          end
          report.endpoints[#report.endpoints + 1] = model.endpoint(endpoint)
        end
      else diagnostics.add(report.diagnostics, { file = path }, tostring(parsed)) end
    end
  end
  return report
end
return M
