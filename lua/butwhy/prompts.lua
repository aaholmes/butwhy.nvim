-- Prompt templates: plain Markdown files in <repo>/prompts with ${context.<field>} and
-- ${butwhy.<helper>} placeholders. Read and filled here, so no YAML parser is needed.
local M = {}

local RADIUS = 40 -- lines of context on each side of the highlight

-- prompts/ sits two levels above this file: <root>/lua/butwhy/prompts.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
M.dir = root .. '/prompts'

---The lines around the highlight, which the prompts send as context only.
function M.surrounding(ctx)
  local total = vim.api.nvim_buf_line_count(ctx.bufnr)
  local first = math.max(ctx.start_line - RADIUS, 1)
  local last = math.min(ctx.end_line + RADIUS, total)
  return table.concat(vim.api.nvim_buf_get_lines(ctx.bufnr, first - 1, last, false), '\n')
end

function M.filename(ctx) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.bufnr), ':t') end

---Fill prompts/<name>.md for a buffer context. Unknown placeholders are left as they are.
function M.render(name, ctx)
  local text = vim.trim(table.concat(vim.fn.readfile(M.dir .. '/' .. name .. '.md'), '\n'))
  return (text:gsub('%${(%w+)%.([%w_]+)}', function(ns, key)
    if ns == 'context' and ctx[key] ~= nil then return tostring(ctx[key]) end
    if ns == 'butwhy' and type(M[key]) == 'function' then return M[key](ctx) end
  end))
end

return M
