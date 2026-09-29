-- End-to-end checks for the ask pop-up, using a mock model server. Run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/ask_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq

vim.o.columns, vim.o.lines = 200, 50

local server = dofile(root .. '/tests/mock_llm.lua').start { { 'Line 100 sets ', 'ANSWER_ONE.' }, { 'ANSWER_TWO.' } }
local config = require 'codecompanion.config'
config.adapters.http.mock = function()
  return require('codecompanion.adapters').extend('openai_compatible', {
    env = { url = 'http://127.0.0.1:' .. server.port, chat_url = '/v1/chat/completions', api_key = 'HOME' },
    schema = { model = { default = 'mock-model' } },
  })
end
require('butwhy').setup { adapter = 'mock', background = root .. '/tests/fixtures/background.md' }

local done = 0
vim.api.nvim_create_autocmd('User', { pattern = 'CodeCompanionChatDone', callback = function() done = done + 1 end })

local file = vim.fn.tempname() .. '.py'
local lines = {}
for i = 1, 200 do
  lines[i] = 'line ' .. i
end
vim.fn.writefile(lines, file)
vim.cmd.edit(file)
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(source_win, { 100, 0 })
vim.cmd 'normal! zz'
vim.cmd.redraw()

vim.cmd '100,101ButwhyAsk'
vim.wait(300)
local chat = require('codecompanion').last_chat()
local win = chat and chat.ui.winnr

local ns = vim.api.nvim_create_namespace 'butwhy.popup'
local function visible()
  local hidden, shown = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines then hidden[m[2]] = true end
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    if not hidden[i - 1] and vim.trim(l) ~= '' then table.insert(shown, l) end
  end
  return shown
end

check('the ask pop-up opens under the highlight, titled, without sending anything', function()
  assert(chat, 'no chat')
  local cfg = vim.api.nvim_win_get_config(win)
  assert(cfg.relative ~= '', 'not floating')
  local title = type(cfg.title) == 'table' and cfg.title[1][1] or tostring(cfg.title)
  assert(title:find('ask', 1, true), 'title = ' .. title)
  eq(cfg.row, vim.fn.screenpos(source_win, 101, 1).row, 'row under the highlight')
  eq(#server.requests, 0, 'requests before a question')
end)

check('the highlight is coloured and the cursor waits in insert mode', function()
  local hl = vim.api.nvim_create_namespace 'butwhy.highlight'
  eq(#vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(source_win), hl, 0, -1, {}), 1, 'highlight')
  eq(vim.api.nvim_get_current_win(), win, 'focus')
  -- The pop-up queues a keypress that enters Insert mode. Process the queue ('x' leaves Insert
  -- mode again at the end, so the script does not block) and record that Insert mode was entered.
  local entered = false
  vim.api.nvim_create_autocmd('InsertEnter', { once = true, callback = function() entered = vim.api.nvim_get_current_win() == win end })
  vim.api.nvim_feedkeys('', 'x', false)
  eq(entered, true, 'entered Insert mode in the pop-up')
end)

check('a hint says what to do, and no prompt or context is visible', function()
  local hint = ''
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      hint = hint .. chunk[1]
    end
  end
  assert(hint:lower():find('ask', 1, true), 'hint = ' .. vim.inspect(hint))
  eq(#visible(), 0, 'visible lines: ' .. vim.inspect(visible()))
end)

vim.api.nvim_buf_set_lines(chat.bufnr, -1, -1, false, { 'Why line 100?' })
chat:submit()
vim.wait(5000, function() return done >= 1 end, 20)
vim.wait(200)

check('the question is sent after the hidden highlight and context', function()
  eq(#server.requests, 1, 'requests')
  local msgs = server.requests[1].messages
  local all = ''
  for _, m in ipairs(msgs) do
    all = all .. '\n' .. tostring(m.content)
  end
  assert(msgs[1].role == 'system' and msgs[1].content:find('HIGHLIGHT is the topic', 1, true), 'system prompt')
  assert(all:find('Linear algebra, probability', 1, true), 'background missing')
  assert(all:find('HIGHLIGHT (lines 100-101)', 1, true), 'highlight missing')
  eq(msgs[#msgs].role, 'user', 'last role')
  assert(msgs[#msgs].content:find('Why line 100?', 1, true), 'question missing: ' .. msgs[#msgs].content)
end)

check('the pop-up shows the question and the answer only, and the hint is gone', function()
  eq(table.concat(visible(), '\n'), 'Why line 100?\nLine 100 sets ANSWER_ONE.', 'visible')
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
    assert(not m[4].virt_text, 'hint still shown')
  end
  eq(vim.api.nvim_win_get_config(win).height, vim.api.nvim_win_text_height(win, {}).all, 'height fits')
end)

check('a second question continues the conversation', function()
  vim.api.nvim_buf_set_lines(chat.bufnr, -1, -1, false, { 'And line 101?' })
  chat:submit()
  vim.wait(5000, function() return done >= 2 end, 20)
  local msgs = server.requests[2].messages
  assert(msgs[#msgs].content:find('And line 101?', 1, true), 'second question missing')
  local joined = ''
  for _, m in ipairs(msgs) do
    joined = joined .. tostring(m.content)
  end
  assert(joined:find('ANSWER_ONE', 1, true), 'first answer not sent back')
end)

h.finish()
