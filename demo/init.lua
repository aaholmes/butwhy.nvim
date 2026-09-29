-- Minimal Neovim config for recording the README GIF (from the repo root: vhs demo/demo.tape).
-- Loads this repo, CodeCompanion and a colour scheme, nothing personal.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.rtp:prepend(root)
for _, dep in ipairs { 'plenary.nvim', 'codecompanion.nvim', 'kanagawa.nvim' } do
  vim.cmd.packadd(dep)
end

vim.g.mapleader = ' '
vim.o.termguicolors = true
vim.o.number = true
vim.o.showmode = false
vim.o.swapfile = false
vim.cmd.colorscheme 'kanagawa'

require('codecompanion').setup { display = { chat = { show_settings = false } } }
require('butwhy').setup { background = root .. '/demo/background.md' }
