-- End-to-end checks for the explain pop-up, using a mock model server. Run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/popup_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq

-- A wide editor, so a pop-up sized to the editor and one sized to its text are easy to tell apart.
vim.o.columns, vim.o.lines = 200, 50

local ANSWER = 'It means MOCK_ANSWER here.'
local LONG = string.rep('Follow-up answer words ', 12) -- 276 characters on one line
local server = dofile(root .. '/tests/mock_llm.lua').start {
  { 'It means ', 'MOCK_ANSWER here.' },
  { LONG },
  { 'Level zero answer.' },
  { 'Level one answer.' },
  { 'Level two answer.' },
}

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
vim.api.nvim_win_set_cursor(source_win, { 100, 0 })
vim.cmd 'normal! zz'
vim.cmd.redraw()

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

-- Editor rows (0-based) of the first and last screen lines of the highlight in the source window.
local function highlight_rows(first, last)
  local top = vim.fn.screenpos(source_win, first, 1).row - 1
  local bottom = vim.fn.screenpos(source_win, last, math.max(1, #vim.fn.getbufline(vim.api.nvim_win_get_buf(source_win), last)[1])).row - 1
  return top, bottom
end

check('the pop-up opens right under the highlight', function()
  local cfg = vim.api.nvim_win_get_config(win)
  local _, bottom = highlight_rows(100, 101)
  eq(cfg.relative, 'editor', 'relative')
  eq(cfg.row, bottom + 1, 'border row vs the line below the highlight')
  eq(cfg.col, vim.fn.screenpos(source_win, 100, 1).col - 1, 'left edge vs the text column')
end)

check('the pop-up opens below virtual lines under the highlight (a rendered equation)', function()
  -- snacks.nvim draws a display equation's extra rows as virtual lines under its line.
  local fake = vim.api.nvim_create_namespace 'butwhy_test_source_virt'
  local src = vim.api.nvim_win_get_buf(source_win)
  vim.api.nvim_buf_set_extmark(src, fake, 100, 0, { virt_lines = { { { 'row 2' } }, { { 'row 3' } } } })
  vim.cmd.redraw()
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.wait(200)
  local row = vim.api.nvim_win_get_config(win).row
  vim.api.nvim_buf_clear_namespace(src, fake, 0, -1)
  vim.cmd.redraw()
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.wait(200)
  local _, bottom = highlight_rows(100, 101)
  eq(row, bottom + 1 + 2, 'border row vs the row after the two virtual lines')
  eq(vim.api.nvim_win_get_config(win).row, bottom + 1, 'border row once they are gone')
end)

local hl_ns = vim.api.nvim_create_namespace 'butwhy.highlight'
local function highlight_marks()
  return vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(source_win), hl_ns, 0, -1, { details = true })
end

check('the highlighted text is orange while the pop-up is open', function()
  local marks = highlight_marks()
  eq(#marks, 1, 'highlight extmarks')
  local m = marks[1]
  eq(m[2], 99, 'start row')
  eq(m[4].end_row, 100, 'end row')
  eq(m[4].hl_group, 'ButwhyHighlight', 'hl group')
  -- Same colours as the yank flash from vim.hl.on_yank(), which uses IncSearch.
  eq(vim.api.nvim_get_hl(0, { name = 'ButwhyHighlight' }).link, 'IncSearch', 'link')
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

check('the answer is scrolled into view, not above the top of the window', function()
  -- With the cursor on the chat's last line, Neovim would scroll that line to the top; the
  -- whole conversation fits, so the view must start at the first line.
  eq(vim.fn.getwininfo(win)[1].topline, 1, 'topline')
end)

check('the pop-up has no line numbers or sign column', function()
  eq(vim.wo[win].number, false, 'number')
  eq(vim.wo[win].relativenumber, false, 'relativenumber')
  eq(vim.wo[win].signcolumn, 'no', 'signcolumn')
end)

check('the pop-up is sized to a short answer', function()
  local cfg = vim.api.nvim_win_get_config(win)
  assert(cfg.width <= 40, 'width ' .. cfg.width .. ' for a ' .. #ANSWER .. '-character answer')
  eq(cfg.height, vim.api.nvim_win_text_height(win, {}).all, 'height vs displayed lines')
  assert(cfg.height <= 2, 'height ' .. cfg.height)
end)

check('virtual lines added by another plugin (a rendered equation) resize the pop-up', function()
  -- snacks.nvim draws a display equation as an image in virtual lines below its line, without
  -- changing the buffer; the pop-up must grow and keep the answer in view.
  local fake = vim.api.nvim_create_namespace 'butwhy_test_virt_lines'
  local before = vim.api.nvim_win_get_config(win).height
  local rows = {}
  for i = 1, 4 do
    rows[i] = { { 'image row ' .. i, 'Normal' } }
  end
  local row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    if l:find(ANSWER, 1, true) then row = i - 1 end
  end
  vim.api.nvim_buf_set_extmark(chat.bufnr, fake, row, 0, { virt_lines = rows })
  vim.cmd.redraw()
  vim.wait(300)
  vim.cmd.redraw()
  local cfg = vim.api.nvim_win_get_config(win)
  local grown = cfg.height
  local topline = vim.fn.getwininfo(win)[1].topline
  vim.api.nvim_buf_clear_namespace(chat.bufnr, fake, 0, -1)
  vim.cmd.redraw()
  vim.wait(300)
  eq(grown, before + 4, 'height with four virtual lines')
  eq(topline, 1, 'topline with four virtual lines')
  eq(vim.api.nvim_win_get_config(win).height, before, 'height after they are removed')
end)

check('an answer taller than the editor fills the pop-up down to its last line', function()
  -- Too tall to fit, the view must end at the last line (where the cursor is) with no empty
  -- rows below it, not show that line at the top and the rest of the window empty.
  local fake = vim.api.nvim_create_namespace 'butwhy_test_virt_lines'
  local rows = {}
  for i = 1, 60 do
    rows[i] = { { 'image row ' .. i, 'Normal' } }
  end
  local row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    if l:find(ANSWER, 1, true) then row = i - 1 end
  end
  vim.api.nvim_buf_set_extmark(chat.bufnr, fake, row, 0, { virt_lines = rows })
  vim.cmd.redraw()
  vim.wait(300)
  vim.cmd.redraw()
  local height = vim.api.nvim_win_get_height(win)
  local info = vim.fn.getwininfo(win)[1]
  local shown = vim.api.nvim_win_text_height(win, { start_row = info.topline - 1 }).all
  local last = vim.api.nvim_buf_line_count(chat.bufnr)
  vim.api.nvim_buf_clear_namespace(chat.bufnr, fake, 0, -1)
  vim.cmd.redraw()
  vim.wait(300)
  eq(height, vim.o.lines - 6, 'height capped by the editor')
  eq(info.botline, last, 'last line shown')
  assert(shown >= height, string.format('only %d of %d rows filled from topline %d', shown, height, info.topline))
  eq(vim.fn.getwininfo(win)[1].topline, 1, 'topline once it fits again')
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

check('a long answer wraps at 80 columns and the height follows', function()
  vim.wait(200) -- let the scheduled refit after the last streamed chunk run
  local cfg = vim.api.nvim_win_get_config(win)
  eq(cfg.width, 80, 'width')
  eq(cfg.height, vim.api.nvim_win_text_height(win, {}).all, 'height vs displayed lines')
  assert(cfg.height >= 5, 'height ' .. cfg.height .. ' too small for the question plus a wrapped answer')
end)

check('reopening the pop-up keeps its style and size', function()
  chat.ui:hide()
  vim.wait(200)
  eq(#highlight_marks(), 0, 'highlight while hidden')
  chat.ui:open()
  vim.wait(200)
  local w = chat.ui.winnr
  eq(vim.wo[w].number, false, 'number after reopen')
  eq(vim.api.nvim_win_get_config(w).height, vim.api.nvim_win_text_height(w, {}).all, 'height after reopen')
  local _, bottom = highlight_rows(100, 101)
  eq(vim.api.nvim_win_get_config(w).row, bottom + 1, 'position after reopen')
  eq(#highlight_marks(), 1, 'highlight after reopen')
end)

check('closing the pop-up clears the highlight', function()
  vim.api.nvim_win_close(chat.ui.winnr, true)
  vim.wait(200)
  eq(#highlight_marks(), 0, 'highlight after close')
end)

check('near the bottom of the window the pop-up opens above the highlight', function()
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 200, 0 })
  vim.cmd 'normal! zb'
  vim.cmd.redraw()
  vim.cmd '199,200ButwhyExplain'
  vim.wait(5000, function() return done >= 3 end, 20)
  vim.wait(200)
  local c = require('codecompanion').last_chat()
  local cfg = vim.api.nvim_win_get_config(c.ui.winnr)
  local top = highlight_rows(199, 200)
  eq(cfg.row + cfg.height + 2, top, 'bottom border row + 1 vs the highlight top row')
end)

-- Drill-down, on the pop-up opened by the previous check (lines 199-200).
local drill = require('codecompanion').last_chat()

local function press_simpler()
  vim.api.nvim_set_current_win(drill.ui.winnr)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<leader>ws', true, false, true), 'x', false)
end

local function title_of(w)
  local t = vim.api.nvim_win_get_config(w).title
  return type(t) == 'table' and t[1][1] or tostring(t)
end

check('<leader>ws asks for the next level, hidden from the pop-up', function()
  press_simpler()
  vim.wait(5000, function() return done >= 4 end, 20)
  vim.wait(200)
  eq(#server.requests, 4, 'requests sent')
  local msgs = server.requests[4].messages
  eq(msgs[#msgs].role, 'user', 'last role')
  assert(msgs[#msgs].content:find('level 1', 1, true), 'level missing: ' .. msgs[#msgs].content)
  local ns = vim.api.nvim_create_namespace 'butwhy.popup'
  local hidden = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(drill.bufnr, ns, 0, -1, { details = true })) do
    hidden[m[2]] = true
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(drill.bufnr, 0, -1, false)) do
    assert(not (l:find('level 1', 1, true) and not hidden[i - 1]), 'drill-down request visible: ' .. l)
  end
end)

-- Visible lines of the drill-down pop-up.
local function drill_visible()
  local ns = vim.api.nvim_create_namespace 'butwhy.popup'
  local hidden, shown = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(drill.bufnr, ns, 0, -1, { details = true })) do
    hidden[m[2]] = true
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(drill.bufnr, 0, -1, false)) do
    if not hidden[i - 1] and vim.trim(l) ~= '' then table.insert(shown, l) end
  end
  return shown
end

check('the pop-up shows only the simpler answer, and the title shows the level', function()
  eq(table.concat(drill_visible(), '\n'), 'Level one answer.', 'visible text')
  assert(title_of(drill.ui.winnr):find('level 1', 1, true), 'title = ' .. title_of(drill.ui.winnr))
  eq(vim.api.nvim_win_get_config(drill.ui.winnr).height, vim.api.nvim_win_text_height(drill.ui.winnr, {}).all, 'height')
end)

check('pressing again goes one level further', function()
  press_simpler()
  vim.wait(5000, function() return done >= 5 end, 20)
  vim.wait(200)
  local msgs = server.requests[5].messages
  assert(msgs[#msgs].content:find('level 2', 1, true), 'level missing: ' .. msgs[#msgs].content)
  eq(table.concat(drill_visible(), '\n'), 'Level two answer.', 'visible text')
  assert(title_of(drill.ui.winnr):find('level 2', 1, true), 'title = ' .. title_of(drill.ui.winnr))
end)

check(':ButwhySimpler exists for users without the keymap', function() eq(vim.fn.exists(':ButwhySimpler'), 2, 'command') end)

check('the border and title use the highlight colour', function()
  local w = drill.ui.winnr
  local whl = vim.wo[w].winhighlight
  assert(whl:find('FloatBorder:ButwhyBorder', 1, true), 'winhighlight = ' .. whl)
  assert(whl:find('FloatTitle:ButwhyBorder', 1, true), 'winhighlight = ' .. whl)
  local src = vim.api.nvim_get_hl(0, { name = 'ButwhyHighlight', link = false })
  eq(vim.api.nvim_get_hl(0, { name = 'ButwhyBorder', link = false }).fg, src.bg or src.fg, 'border colour')
end)

check('the footer names the model', function()
  local f = vim.api.nvim_win_get_config(drill.ui.winnr).footer
  local text = type(f) == 'table' and f[1][1] or tostring(f)
  assert(text:find('mock-model', 1, true), 'footer = ' .. vim.inspect(f))
end)

local hl_ns2 = vim.api.nvim_create_namespace 'butwhy.highlight'
local function source_marks() return #vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(source_win), hl_ns2, 0, -1, {}) end

for _, key in ipairs { 'q', '<Esc>' } do
  check(key .. ' in Normal mode closes the pop-up and clears the highlight', function()
    if not (drill.ui.winnr and vim.api.nvim_win_is_valid(drill.ui.winnr)) then
      drill.ui:open()
      vim.wait(200)
    end
    local w = drill.ui.winnr
    vim.api.nvim_set_current_win(w)
    vim.cmd 'stopinsert'
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'x', false)
    vim.wait(200)
    eq(vim.api.nvim_win_is_valid(w), false, 'window still open')
    eq(source_marks(), 0, 'highlight left behind')
    eq(vim.api.nvim_buf_is_valid(drill.bufnr), true, 'chat buffer kept for reopening')
  end)
end

h.finish()
