local providers = require("restful.providers")
local M = {}
function M.detect(context, opts)
  context, opts = context or {}, opts or {}; local result = {}
  local enabled_providers = opts.providers
  if type(enabled_providers) ~= "table" or #enabled_providers == 0 then enabled_providers = providers.list() end
  for _, provider in ipairs(enabled_providers) do
    local requested = opts.provider
    local matches = not requested or requested == provider.id or requested == provider.id:gsub("^java%-", "")
    if type(provider) == "table" and matches then
      local ok, detection = false, nil
      if provider.detect then ok, detection = pcall(provider.detect, context) end
      if ok and detection then detection.provider = provider.id; result[#result + 1] = detection end
    end
  end
  return result
end
function M.for_file(text, path, opts)
  opts = opts or {}; local lower = (path or ""):lower(); local context = { text = text or "", path = path, package_json = opts.package_json or "" }
  local detected = M.detect(context, opts)
  if #detected > 0 then return detected end
  local fallback = lower:match("%.py$") and "python"
    or lower:match("%.go$") and "go"
    or lower:match("%.tsx?$") and "typescript"
    or lower:match("%.[cm]?js$") and "javascript"
    or lower:match("%.java$") and "java"
    or nil
  local evidence = tostring(text or "")
  local hints = {
    spring = evidence:find("@RestController", 1, true) or evidence:find("@RequestMapping", 1, true),
    jaxrs = evidence:find("@Path", 1, true) and (evidence:find("@GET", 1, true) or evidence:find("@POST", 1, true)),
    fastapi = evidence:find("APIRouter", 1, true) or evidence:find("FastAPI", 1, true),
    flask = evidence:find("Blueprint", 1, true) or evidence:find("Flask", 1, true) or evidence:find("@app.route", 1, true),
    django = evidence:find("urlpatterns", 1, true) or evidence:find("path(", 1, true) or evidence:find("re_path(", 1, true),
    gin = evidence:find("gin-gonic/gin", 1, true) or evidence:find("gin.Default", 1, true) or evidence:find("gin.New", 1, true),
    chi = evidence:find("go-chi/chi", 1, true) or evidence:find("chi.NewRouter", 1, true),
    net_http = evidence:find("net/http", 1, true) or evidence:find("http.Handle", 1, true),
    express = evidence:find("express", 1, true) and (evidence:find("Router", 1, true) or evidence:find("app.get", 1, true)),
    fastify = evidence:find("fastify", 1, true) and (evidence:find(".route", 1, true) or evidence:find(".register", 1, true)),
    nest = evidence:find("@Controller", 1, true) or evidence:find("@nestjs/", 1, true),
  }
  local enabled_providers = opts.providers
  if type(enabled_providers) ~= "table" or #enabled_providers == 0 then enabled_providers = providers.list() end
  local result = {}; for _, provider in ipairs(enabled_providers) do
    local languages = provider.languages or ({
      fastapi = { "python" }, flask = { "python" }, django = { "python" },
      spring = { "java" }, jaxrs = { "java" },
      net_http = { "go" }, gin = { "go" }, chi = { "go" },
      express = { "javascript", "typescript" }, fastify = { "javascript", "typescript" }, nest = { "javascript", "typescript" },
    })[provider.id] or {}
    local matches = false; for _, language in ipairs(languages) do if language == fallback then matches = true end end
    local requested = opts.provider
    local provider_matches = not requested or requested == provider.id or requested == provider.id:gsub("^java%-", "")
    if provider_matches and fallback and matches then
      local hint = hints[provider.id] or hints[provider.id:gsub("^java%-", "")]
      if hint or requested then result[#result + 1] = { provider = provider.id, language = fallback } end
    end
  end
  return result
end
return M
