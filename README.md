# restful.nvim

Discover server API endpoints in Java, Python, Go, JavaScript, and TypeScript projects, then jump to their source or generate an HTTP request from a Snacks picker.

## Requirements

- Neovim 0.10 or newer
- `rg` (ripgrep)
- `folke/snacks.nvim` for the interactive picker
- `mistweaverco/kulala.nvim` is optional and enables sending generated requests
- A Java Tree-sitter parser is optional; Spring parsing has a fallback parser

## Installation

```lua
{
  "yelog/restful.nvim",
  dependencies = {
    "folke/snacks.nvim",
    { "mistweaverco/kulala.nvim", ft = { "http", "rest" }, optional = true },
  },
  opts = {},
  keys = {
    { "<leader>iq", function() require("restful").open() end, desc = "Query API endpoint" },
  },
}
```

## Commands

- `:Restful [METHOD] [query]` opens the endpoint picker
- `:RestfulRefresh[!]` refreshes the current project index
- `:RestfulDiagnostics` opens current index diagnostics in the quickfix list
- `:RestfulFrameworks` lists detected frameworks and endpoint counts

Inside the picker, Enter jumps to the source, `<C-O>` opens an HTTP draft, and `<C-R>` runs it through Kulala when installed. Unsafe methods are confirmed by default.

## Configuration

```lua
require("restful").setup({
  scan = {
    exclude = { ".git", "node_modules", "vendor", "target", "build", "dist" },
    parse_budget_ms = 6,
  },
  request = {
    base_url_variable = "API_BASE_URL",
    fallback_base_url = "http://localhost:8080",
    confirm_unsafe_methods = true,
  },
})
```

The built-in providers are Spring MVC, JAX-RS, FastAPI, Flask, Django, Gin, Chi, Go `net/http`, Express, Fastify, and NestJS. Parsing is primarily static and file-local; runtime routes and reliable cross-file router resolution are outside the current scope.

## Provider API

Custom providers can be registered with `require("restful").register_provider(provider)`. A provider has an `id`, `languages`, optional `detect`, and either `parse` or `extract` plus optional `resolve`. The scanner normalizes results into the endpoint model used by the picker and request generator.

## Testing

```bash
make test
make format-check
```

Run `:checkhealth restful` to inspect runtime dependencies and loaded providers.
