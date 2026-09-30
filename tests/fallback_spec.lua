-- End-to-end checks for the fallback model: when the main model's request fails, the pop-up asks
-- the fallback instead. Run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/fallback_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq

local mock = dofile(root .. '/tests/mock_llm.lua')
-- 402 rather than OpenAI's 429: curl retries a 429 three times first, which would use up the replies.
local NO_CREDIT = { status = 402, body = '{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}' }
local main = mock.start { NO_CREDIT, { 'Main answer.' } }
local backup = mock.start { { 'Backup answer.' }, { 'Backup simpler answer.' } }

local config = require 'codecompanion.config'
local function adapter(port, model)
  return function()
    return require('codecompanion.adapters').extend('openai_compatible', {
      env = { url = 'http://127.0.0.1:' .. port, chat_url = '/v1/chat/completions', api_key = 'HOME' },
      schema = { model = { default = model } },
    })
  end
end
config.adapters.http.main = adapter(main.port, 'main-model')
config.adapters.http.backup = adapter(backup.port, 'backup-model')
require('butwhy').setup { adapter = 'main', fallback = 'backup', background = root .. '/tests/fixtures/background.md' }

local done = 0
vim.api.nvim_create_autocmd('User', { pattern = 'CodeCompanionChatDone', callback = function() done = done + 1 end })

local file = vim.fn.tempname() .. '.py'
vim.fn.writefile({ 'x = 1', 'y = 2' }, file)
vim.cmd.edit(file)

vim.cmd '1ButwhyExplain'
local chat = require('codecompanion').last_chat()
vim.wait(5000, function() return #backup.requests >= 1 and done >= 2 end, 20)
vim.wait(100)
local function shown() return table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), '\n') end

check('a failed request is sent again to the fallback', function()
  eq(#main.requests, 1, 'requests to the main model')
  eq(#backup.requests, 1, 'requests to the fallback')
  eq(backup.requests[1].model, 'backup-model', 'fallback model')
end)

check('the fallback receives the whole conversation', function()
  eq(vim.inspect(backup.requests[1].messages), vim.inspect(main.requests[1].messages), 'messages')
end)

check('the pop-up shows the fallback answer', function()
  assert(shown():find('Backup answer.', 1, true), 'answer missing from:\n' .. shown())
end)

check('the footer names the fallback model', function()
  local footer = vim.api.nvim_win_get_config(chat.ui.winnr).footer
  assert(vim.inspect(footer):find('backup-model', 1, true), 'footer: ' .. vim.inspect(footer))
end)

check('drilling down stays on the fallback', function()
  require('butwhy').simpler(chat.bufnr)
  vim.wait(5000, function() return #backup.requests >= 2 and done >= 3 end, 20)
  eq(#main.requests, 1, 'requests to the main model')
  eq(#backup.requests, 2, 'requests to the fallback')
end)

check('the next pop-up tries the main model again', function()
  chat.ui:hide()
  vim.cmd '2ButwhyExplain'
  local second = require('codecompanion').last_chat()
  vim.wait(5000, function() return #main.requests >= 2 and done >= 4 end, 20)
  vim.wait(100)
  eq(#backup.requests, 2, 'requests to the fallback')
  local text = table.concat(vim.api.nvim_buf_get_lines(second.bufnr, 0, -1, false), '\n')
  assert(text:find('Main answer.', 1, true), 'answer missing from:\n' .. text)
end)

h.finish()
