-- End-to-end checks for the explain pop-up, using a mock model server. Run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/popup_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq

local ANSWER = 'It means MOCK_ANSWER here.'
local server = dofile(root .. '/tests/mock_llm.lua').start { 'It means ', 'MOCK_ANSWER here.' }

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

-- The file being read: 200 numbered lines.
local file = vim.fn.tempname() .. '.py'
local lines = {}
for i = 1, 200 do
  lines[i] = 'line ' .. i
end
vim.fn.writefile(lines, file)
vim.cmd.edit(file)
local source_win = vim.api.nvim_get_current_win()

vim.cmd '100,101ButwhyExplain'
local chat = require('codecompanion').last_chat()
vim.wait(5000, function() return done >= 1 and #server.requests >= 1 end, 20)

local win = chat and chat.ui.winnr
local text = chat and table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), '\n') or ''

check('a request completes', function()
  assert(chat, 'no chat was created')
  eq(#server.requests, 1, 'requests sent')
  eq(done, 1, 'ChatDone events')
end)

check('the answer opens in a titled floating window', function()
  local cfg = vim.api.nvim_win_get_config(win)
  assert(cfg.relative ~= '', 'window is not floating')
  local title = type(cfg.title) == 'table' and cfg.title[1][1] or cfg.title
  assert(tostring(title):find('butwhy', 1, true), 'title = ' .. vim.inspect(cfg.title))
  assert(win ~= source_win, 'answer replaced the source window')
end)

check('other chats keep the configured layout', function() eq(config.display.chat.window.layout, 'vertical', 'global layout') end)

check('the pop-up shows the answer', function() assert(text:find(ANSWER, 1, true), 'answer missing from:\n' .. text) end)

-- What the reader sees: buffer lines not hidden by a conceal_lines extmark.
local function visible_text()
  local ns = vim.api.nvim_create_namespace 'butwhy.popup'
  local hidden = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines then hidden[m[2]] = true end
  end
  local shown = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    if not hidden[i - 1] then table.insert(shown, l) end
  end
  return table.concat(shown, '\n')
end

check('the pop-up shows no prompt, highlight, surroundings or rules context', function()
  local shown = visible_text()
  for _, s in ipairs { 'patient tutor', 'HIGHLIGHT', 'SURROUNDING', 'line 100', 'background.md', 'Linear algebra', '## ' } do
    assert(not shown:find(s, 1, true), string.format('%q visible in:\n%s', s, shown))
  end
end)

check('the answer is the first line shown, with no run of blank lines', function()
  local shown = visible_text()
  eq(vim.split(shown, '\n')[1], ANSWER, 'first visible line')
  assert(not shown:find('\n\n\n', 1, true), 'run of blank lines in:\n' .. shown)
end)

check('chat role headers are concealed', function()
  local ns = vim.api.nvim_create_namespace 'butwhy.popup'
  local concealed = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines then concealed[m[2]] = true end
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    if l:match '^## ' then assert(concealed[i - 1], 'header not concealed: ' .. l) end
  end
  assert(vim.wo[win].conceallevel > 0, 'conceallevel is 0')
end)

check('the model receives the system prompt, background and exactly one user turn', function()
  local req = server.requests[1]
  eq(req.model, 'mock-model', 'model')
  local users, system_text, all = {}, '', ''
  for _, m in ipairs(req.messages) do
    local c = type(m.content) == 'string' and m.content or vim.inspect(m.content)
    all = all .. '\n' .. c
    if m.role == 'user' then table.insert(users, c) end
    if m.role == 'system' then system_text = system_text .. c end
  end
  assert(system_text:find('patient tutor', 1, true), 'system prompt missing')
  assert(all:find('Linear algebra, probability', 1, true), 'background missing')
  local prompts = vim.tbl_filter(function(c) return c:find('HIGHLIGHT (lines 100-101)', 1, true) end, users)
  eq(#prompts, 1, 'user turns carrying the prompt')
  for _, c in ipairs(users) do
    assert(vim.trim(c) ~= '', 'empty user turn sent')
  end
end)

check('a follow-up typed in the pop-up reaches the model with the conversation', function()
  vim.api.nvim_buf_set_lines(chat.bufnr, -1, -1, false, { 'What about line 1?' })
  chat:submit()
  vim.wait(5000, function() return done >= 2 end, 20)
  eq(#server.requests, 2, 'requests sent')
  local msgs = server.requests[2].messages
  local last = msgs[#msgs]
  eq(last.role, 'user', 'last role')
  assert(last.content:find('What about line 1?', 1, true), 'follow-up missing: ' .. vim.inspect(last.content))
  local seen_answer = false
  for _, m in ipairs(msgs) do
    if m.role == 'assistant' and tostring(m.content):find('MOCK_ANSWER', 1, true) then seen_answer = true end
  end
  assert(seen_answer, 'previous answer not sent back')
end)

h.finish()
