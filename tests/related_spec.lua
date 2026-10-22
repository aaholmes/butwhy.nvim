-- End-to-end checks for related text (definitions or documents from outside the surroundings),
-- using a mock model server. Run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/related_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq

local server = dofile(root .. '/tests/mock_llm.lua').start { { 'First answer.' }, { 'Second answer.' } }
local config = require 'codecompanion.config'
config.adapters.http.mock = function()
  return require('codecompanion.adapters').extend('openai_compatible', {
    env = { url = 'http://127.0.0.1:' .. server.port, chat_url = '/v1/chat/completions', api_key = 'HOME' },
    schema = { model = { default = 'mock-model' } },
  })
end

local done = 0
vim.api.nvim_create_autocmd('User', { pattern = 'CodeCompanionChatDone', callback = function() done = done + 1 end })

local file = vim.fn.tempname() .. '.py'
local lines = {}
for i = 1, 200 do
  lines[i] = 'line ' .. i
end
vim.fn.writefile(lines, file)
vim.cmd.edit(file)

local function user_turn(req)
  local out = {}
  for _, m in ipairs(req.messages) do
    if m.role == 'user' then out[#out + 1] = type(m.content) == 'string' and m.content or vim.inspect(m.content) end
  end
  return table.concat(out, '\n')
end

local seen
require('butwhy').setup {
  adapter = 'mock',
  background = root .. '/tests/fixtures/background.md',
  related = function(context)
    seen = context
    return { { source = 'other.py:1-2', text = 'RELATED_SNIPPET_TEXT' } }
  end,
}
vim.cmd '100,101ButwhyExplain'
vim.wait(5000, function() return done >= 1 and #server.requests >= 1 end, 20)

check('the related provider is called with the highlight context', function()
  assert(seen, 'provider not called')
  eq(seen.start_line, 100, 'start line')
  eq(seen.end_line, 101, 'end line')
end)

check('related text reaches the model in the user turn', function()
  local user = user_turn(server.requests[1])
  assert(user:find('RELATED TEXT', 1, true) and user:find('RELATED_SNIPPET_TEXT', 1, true), 'related text missing:\n' .. user)
end)

check('related text is hidden from the pop-up', function()
  local chat = require('codecompanion').last_chat()
  local visible = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    visible[#visible + 1] = l
  end
  -- The user turn is a hidden message, so it is never written to the chat buffer.
  assert(not table.concat(visible, '\n'):find('RELATED_SNIPPET_TEXT', 1, true), 'related text shown in pop-up')
end)

check('a provider that errors does not stop the pop-up', function()
  vim.cmd 'silent! only'
  require('butwhy').setup {
    adapter = 'mock',
    background = root .. '/tests/fixtures/background.md',
    related = function() error 'boom' end,
  }
  vim.cmd.edit(file)
  vim.cmd '100,101ButwhyExplain'
  vim.wait(5000, function() return done >= 2 and #server.requests >= 2 end, 20)
  eq(#server.requests, 2, 'requests sent')
  assert(not user_turn(server.requests[2]):find('RELATED TEXT', 1, true), 'related block present after an error')
end)


h.finish()
