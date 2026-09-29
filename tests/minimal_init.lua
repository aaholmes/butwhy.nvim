-- Minimal config for the headless tests: this repo, CodeCompanion and plenary, nothing personal.
-- Dependencies are found with :packadd (e.g. installed by vim.pack), or under $BUTWHY_DEPS if set.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.rtp:prepend(root)

for _, dep in ipairs { 'plenary.nvim', 'codecompanion.nvim' } do
  if vim.env.BUTWHY_DEPS then
    vim.opt.rtp:prepend(vim.env.BUTWHY_DEPS .. '/' .. dep)
  else
    vim.cmd.packadd(dep)
  end
end

vim.g.mapleader = ' '
require('codecompanion').setup {}
require('butwhy').setup { background = root .. '/tests/fixtures/background.md' }
