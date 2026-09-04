local M = {}

function M.check()
  vim.health.start("restful.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim version is supported")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("rg") == 1 then
    vim.health.ok("ripgrep is available")
  else
    vim.health.error("ripgrep (rg) is required for endpoint discovery")
  end

  local snacks_ok = rawget(_G, "Snacks") and Snacks.picker and type(Snacks.picker.pick) == "function"
  if snacks_ok then
    vim.health.ok("Snacks picker is available")
  else
    vim.health.error("Snacks picker is required for the interactive panel")
  end

  local kulala_ok = pcall(require, "kulala")
  if kulala_ok then
    vim.health.ok("Kulala is available for sending requests")
  else
    vim.health.info("Kulala is optional; request actions will open drafts")
  end

  local providers = require("restful.providers").list()
  vim.health.ok(string.format("%d built-in endpoint providers loaded", #providers))
end

return M
