local treesitter = require("restful.treesitter")
local M = {}

local function field(node, name)
  local values = node:field(name)
  return values and values[1]
end

local function annotation(node, source)
  local name = field(node, "name")
  if not name then
    local text = treesitter.node_text(node, source)
    name = text:match("@([%w_$.]+)")
  else
    name = treesitter.node_text(name, source)
  end
  local text = treesitter.node_text(node, source)
  local line, column = treesitter.position(node)
  return { name = name and name:match("([%w_]+)$") or "", arguments = text:match("^@[%w_$.]+%s*(%b())"), text = text, line = line, column = column }
end

local function annotations(node, source)
  local result = {}
  local modifiers = field(node, "modifiers")
  if not modifiers then
    for child in node:iter_children() do
      if child:type() == "modifiers" then modifiers = child; break end
    end
  end
  if not modifiers then return result end
  for child in modifiers:iter_children() do
    local kind = child:type()
    if kind == "annotation" or kind == "marker_annotation" then result[#result + 1] = annotation(child, source) end
  end
  return result
end

local function declarations(node, source)
  local result = {}
  local function visit(current, owner)
    local kind = current:type()
    local type_kind = ({ class_declaration = "class", interface_declaration = "interface", record_declaration = "record" })[kind]
    local current_owner = owner
    if type_kind then
      local name_node = field(current, "name")
      local item = { kind = type_kind, name = name_node and treesitter.node_text(name_node, source) or "", line = treesitter.position(current), annotations = annotations(current, source), methods = {}, types = {} }
      if owner then owner.types[#owner.types + 1] = item else result[#result + 1] = item end
      current_owner = item
    elseif kind == "method_declaration" and owner then
      local name_node = field(current, "name")
      local line, column = treesitter.position(current)
      if name_node then line, column = treesitter.position(name_node) end
      owner.methods[#owner.methods + 1] = {
        name = name_node and treesitter.node_text(name_node, source) or "",
        line = line,
        column = column,
        signature = treesitter.node_text(current, source),
        annotations = annotations(current, source),
      }
    end
    for child in current:iter_children() do visit(child, current_owner) end
  end
  visit(node, nil)
  return result
end

function M.parse(text)
  local tree, err = treesitter.parse(text or "", "java")
  if not tree then return nil, err end
  return declarations(tree:root(), text or "")
end

return M
