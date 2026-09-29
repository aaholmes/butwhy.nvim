-- Helpers for the butwhy prompts. CodeCompanion loads this file because it sits next to
-- the Markdown prompts, and replaces ${butwhy.<fn>} with fn's return value.
local M = {}

local RADIUS = 40 -- lines of context on each side of the highlight

function M.surrounding(args)
  local ctx = args.context
  local total = vim.api.nvim_buf_line_count(ctx.bufnr)
  local first = math.max(ctx.start_line - RADIUS, 1)
  local last = math.min(ctx.end_line + RADIUS, total)
  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, first - 1, last, false)
  return table.concat(lines, "\n")
end

function M.filename(args)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.context.bufnr), ":t")
end

return M
