local declarations = require("restful.providers.java.declarations")
local fallback = require("restful.providers.java.fallback")
local model = require("restful.model")
local M = { id = "spring", languages = { "java" }, framework = "spring", aliases = { "java-spring" } }

local shortcut_methods = {
  GetMapping = "GET", PostMapping = "POST", PutMapping = "PUT", DeleteMapping = "DELETE",
  PatchMapping = "PATCH", HeadMapping = "HEAD", OptionsMapping = "OPTIONS",
}

local function strings(value)
  local result = {}
  for item in (value or ""):gmatch('"([^"\n]*)"') do result[#result + 1] = item end
  return #result > 0 and result or { "" }
end

local function argument_value(args, key)
  if not args then return nil end
  if key then
    local value = args:match("%f[%w]" .. key .. "%s*=%s*(.-)%s*,?%s*$")
    if value then return value end
  end
  return args:gsub("^%s*%(", ""):gsub("%)%s*$", "")
end

local function annotation_route(item)
  local name, args = item.name, item.arguments
  local methods = {}
  if shortcut_methods[name] then
    methods[1] = shortcut_methods[name]
  elseif name == "RequestMapping" and args then
    for method in args:gmatch("RequestMethod%.([%w_]+)") do methods[#methods + 1] = method end
  elseif name ~= "RequestMapping" then
    return nil
  end
  local path_arg = argument_value(args, "path") or argument_value(args, "value")
  local paths = strings(path_arg or (args and name == "RequestMapping" and argument_value(args) or ""))
  if name == "RequestMapping" and #methods == 0 then methods[1] = "ANY" end
  return { paths = paths, methods = methods, name = name, line = item.line, column = item.column }
end

local function join(left, right)
  return model.join_path(left, right)
end

local function params(signature, file, line)
  local result, arguments = {}, signature:match("%((.*)%)") or ""
  for segment in arguments:gmatch("[^,]+") do
    local annotation_name = segment:match("@([%w_]+)")
    local where = ({ PathVariable = "path", RequestParam = "query", RequestHeader = "header" })[annotation_name]
    if annotation_name == "RequestBody" then where = "body" end
    if where then
      local wire = segment:match('value%s*=%s*"([^"]+)"') or segment:match('name%s*=%s*"([^"]+)"') or segment:match('"([^"]+)"')
      local clean = segment:gsub("@[%w_]+%s*%b()", ""):gsub("@[%w_]+", "")
      local name = clean:match("([%w_]+)%s*$") or wire or "value"
      result[#result + 1] = { name = name, wire_name = wire or name, location = where, source = "declared", location_ref = { file = file, line = line, column = 1 } }
    end
  end
  return result
end

local function annotation_description(annotations)
  for _, annotation in ipairs(annotations or {}) do
    if annotation.name == "Operation" then
      local summary = annotation.arguments and annotation.arguments:match('summary%s*=%s*"([^"]+)"')
      if summary then return summary end
    elseif annotation.name == "ApiOperation" or annotation.name == "AiTool" then
      local value = annotation.arguments and (annotation.arguments:match('value%s*=%s*"([^"]+)"') or annotation.arguments:match('^%(%s*"([^"]+)"'))
      if value then return value end
    end
  end
end

local function javadoc_description(lines, method)
  local first_line = method.line
  for _, annotation in ipairs(method.annotations or {}) do first_line = math.min(first_line, annotation.line or first_line) end
  local cursor = first_line - 1
  while cursor > 0 and vim.trim(lines[cursor] or "") == "" do cursor = cursor - 1 end
  if cursor == 0 or not (lines[cursor] or ""):find("*/", 1, true) then return nil end

  local comments = {}
  while cursor > 0 do
    local line = lines[cursor] or ""
    local text = line:gsub("^%s*/?%*+%s?", ""):gsub("%s*%*/%s*$", "")
    if text ~= "" and not text:match("^@[%w_]+") then table.insert(comments, 1, text) end
    if line:find("/**", 1, true) then break end
    cursor = cursor - 1
  end
  return comments[1]
end

local function extract_types(type_list, filename, lines, result)
  for _, type_decl in ipairs(type_list or {}) do
    local class_paths = { "" }
    for _, item in ipairs(type_decl.annotations) do
      local route = annotation_route(item)
      if route and route.name == "RequestMapping" then class_paths = route.paths end
    end
    for _, method in ipairs(type_decl.methods) do
      for _, item in ipairs(method.annotations) do
        local route = annotation_route(item)
        if route then
          for _, class_path in ipairs(class_paths) do
            for _, method_path in ipairs(route.paths) do
              result[#result + 1] = {
                id = table.concat({ "spring", filename, item.line, method.line, join(class_path, method_path), table.concat(route.methods, ",") }, "|"),
                kind = "server", framework = "spring", language = "java", methods = route.methods,
                path = join(class_path, method_path), raw_path = join(class_path, method_path),
                handler = { file = filename, line = method.line, column = method.column },
                handler_name = method.name, declaration = { file = filename, line = item.line, column = item.column },
                description = annotation_description(method.annotations) or javadoc_description(lines, method),
                parameters = params(method.signature, filename, method.line), body = nil, middleware = {}, provenance = { "@" .. route.name }, confidence = "confirmed", diagnostics = {},
              }
            end
          end
        end
      end
    end
    extract_types(type_decl.types, filename, lines, result)
  end
end

function M.extract(context, file)
  local filename = type(file) == "table" and (file.path or file.name) or file or context.file or context.path or "<buffer>"
  local text = context.source or context.text or (type(file) == "table" and (file.source or file.text)) or ""
  local parser = context.declaration_parser or declarations.parse
  local type_list = parser(text)
  if not type_list then type_list = fallback.parse(text) end
  local result = {}
  extract_types(type_list, filename, vim.split(text, "\n", { plain = true }), result)
  return result
end

function M.resolve(_context, fragments, _graph) return fragments or {} end
return M
