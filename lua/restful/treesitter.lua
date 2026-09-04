local M = {}
function M.available(language)
  local ok, ts = pcall(require, "vim.treesitter")
  return ok and ts and pcall(vim.treesitter.get_parser, 0, language)
end
function M.parse(text, language)
  local ok, parser = pcall(function() return vim.treesitter.get_string_parser(text or "", language) end)
  if not ok then return nil, parser end
  return parser:parse()[1], nil
end
function M.node_text(node, source) return vim.treesitter.get_node_text(node, source) end
function M.position(node)
  local row, column = node:start()
  return row + 1, column + 1
end
return M
