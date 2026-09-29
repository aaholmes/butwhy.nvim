-- butwhy: explain a highlighted passage at the reader's level, or answer questions about it, in a
-- pop-up beside it. Built on CodeCompanion; call setup() after require('codecompanion').setup().
local M = {}

local defaults = {
  -- Reader background, attached to every butwhy chat as a CodeCompanion rules group.
  background = '~/.config/butwhy/background.md',
  -- Any CodeCompanion adapter: a name, { name = ..., model = ... }, or false to use the
  -- chat adapter configured in CodeCompanion.
  adapter = { name = 'ollama_cloud', model = 'gemma4:31b' },
  -- The answer pop-up: any CodeCompanion chat window options, applied to butwhy chats only.
  -- A floating pop-up is resized to fit its text, up to max_width columns.
  window = { layout = 'float', width = 40, height = 1, border = 'rounded', title = ' butwhy ' },
  max_width = 80,
  -- Keys butwhy maps; false (for all, or one entry) maps nothing. The commands work either way.
  keymaps = { explain = '<leader>we', ask = '<leader>wa', simpler = '<leader>ws' },
}

-- The drill-down request. The level counter is kept here, not left to the model.
local SIMPLER = 'Re-explain the HIGHLIGHT at level %d: one layer less jargon than your last answer, '
  .. 'define every term it relied on, and use a simpler example. Still a few sentences.'

local MIN_WIDTH = 30
local hl_ns = vim.api.nvim_create_namespace 'butwhy.highlight'
-- Per pop-up, keyed by chat bufnr: { chat, kind, title, anchor, level, hide_before, asked }.
-- kind is 'explain' or 'ask'; anchor is the highlight it is about ({ win, buf, first, last,
-- first_col, last_col }); hide_before is how many leading buffer lines belong to earlier levels
-- and are hidden; asked is whether an ask pop-up has sent its first question.
local states = {}
local last_popup -- bufnr of the most recently opened pop-up

local ns = vim.api.nvim_create_namespace 'butwhy.popup'

-- Gemma 4 31B on Ollama Cloud, the default: free plan available, prompts not logged or trained
-- on, about a second per answer, and among the most accurate models in the September 2026
-- comparison (see README). Registered only if the user has no adapter of that name.
local function ollama_cloud()
  return require('codecompanion.adapters').extend('openai_compatible', {
    env = { url = 'https://ollama.com', chat_url = '/v1/chat/completions', api_key = 'OLLAMA_API_KEY' },
    schema = { model = { default = 'gemma4:31b' } },
  })
end

-- Mercury (Inception Labs), the fastest option tested, speaks the OpenAI chat format. Registered
-- only if the user has no adapter of that name, so it can be chosen by name without extra setup.
-- reasoning_effort defaults to 'instant': the API's own default, 'medium', spends a few seconds
-- reasoning before the first word, which is too slow for a pop-up.
local function mercury()
  return require('codecompanion.adapters').extend('openai_compatible', {
    env = {
      url = 'https://api.inceptionlabs.ai',
      chat_url = '/v1/chat/completions',
      api_key = 'INCEPTION_API_KEY',
    },
    schema = {
      model = { default = 'mercury-2.5' },
      reasoning_effort = {
        order = 2,
        mapping = 'parameters',
        type = 'enum',
        desc = 'How long the model reasons before answering',
        default = 'instant',
        choices = { 'instant', 'low', 'medium', 'high' },
      },
    },
  })
end

---Build the buffer context the way :CodeCompanion does, but honour a typed range. CodeCompanion
---reads the '< and '> marks, which only match the range when the command came from visual mode.
local function get_context(cmd_opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local context = require('codecompanion.utils.context').get(bufnr, cmd_opts)
  if cmd_opts.range > 0 and (context.start_line ~= cmd_opts.line1 or context.end_line ~= cmd_opts.line2) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, cmd_opts.line1 - 1, cmd_opts.line2, false)
    context.lines, context.code = lines, table.concat(lines, '\n')
    context.start_line, context.end_line = cmd_opts.line1, cmd_opts.line2
    context.start_col, context.end_col = 1, #lines[#lines]
  end
  return context
end

---Hide the lines that are chat plumbing rather than answer: role headers, the context block
---listing the background file, and the blank lines that pad them. Concealed, not deleted,
---because CodeCompanion re-reads them.
local function conceal_plumbing(chat)
  local roles = require('codecompanion.config').interactions.chat.roles
  local llm = type(roles.llm) == 'function' and roles.llm(chat.adapter) or roles.llm
  local headers = { ['## ' .. roles.user] = true, ['## ' .. llm] = true }
  vim.api.nvim_buf_clear_namespace(chat.bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
  local st = states[chat.bufnr]
  local cutoff = st and st.hide_before or 0
  local hide, in_context, prev_hidden = {}, false, true
  for i, line in ipairs(lines) do
    in_context = line == '> Context:' or (in_context and line:match '^> ' ~= nil)
    hide[i] = i <= cutoff or headers[vim.trim(line)] or in_context or (prev_hidden and vim.trim(line) == '')
    prev_hidden = hide[i]
  end
  -- Trailing blank lines too; blank lines between turns stay as separators.
  for i = #lines, 1, -1 do
    if not (hide[i] or vim.trim(lines[i]) == '') then break end
    hide[i] = true
  end
  for i = 1, #lines do
    if hide[i] then vim.api.nvim_buf_set_extmark(chat.bufnr, ns, i - 1, 0, { conceal_lines = '' }) end
  end
end

---In an ask pop-up that has not been used yet, show a placeholder on the input line saying what
---to do. It goes away once the reader types or sends.
local function show_hint(chat)
  local st = states[chat.bufnr]
  if not (st and st.kind == 'ask' and not st.asked) then return end
  local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
  if vim.trim(lines[#lines]) ~= '' then return end
  local modes = require('codecompanion.config').interactions.chat.keymaps.send.modes
  local key = function(k) return type(k) == 'table' and k[1] or k end
  local send = modes.i and (key(modes.i) .. ' (insert) or ') or ''
  local hint = string.format('Ask a question about the highlighted text; send with %s%s', send, key(modes.n) or '<CR>')
  vim.api.nvim_buf_set_extmark(chat.bufnr, ns, #lines - 1, 0, { virt_text = { { hint, 'Comment' } }, virt_text_pos = 'overlay' })
end

---Hide the gutter (line numbers, signs, folds) and enable line concealing in the pop-up.
local function style(win)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, 'no', '0', ''
  wo.conceallevel = 2
end

---Where the pop-up goes (editor row and column of its top-left border corner): directly under
---the highlight, aligned with the text, or directly above it if there is not enough room below.
---Screen positions come from screenpos(), so wrapped lines are accounted for. Centred when the
---highlight is not on screen.
local function place(a, width, height)
  local centred = { row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1), col = math.floor((vim.o.columns - width) / 2) }
  if not (a and vim.api.nvim_win_is_valid(a.win) and vim.api.nvim_win_get_buf(a.win) == a.buf) then return centred end
  local last_text = vim.api.nvim_buf_get_lines(a.buf, a.last - 1, a.last, false)[1] or ''
  local top = vim.fn.screenpos(a.win, a.first, 1)
  local bottom = vim.fn.screenpos(a.win, a.last, math.max(1, #last_text))
  if top.row == 0 or bottom.row == 0 then return centred end
  local col = math.max(0, math.min(top.col - 1, vim.o.columns - width - 2))
  local fits_below = bottom.row + height + 2 <= vim.o.lines - vim.o.cmdheight
  local fits_above = top.row - 1 >= height + 2
  if fits_below or not fits_above then return { row = bottom.row, col = col } end
  return { row = top.row - 1 - height - 2, col = col }
end

---Colour the explained text while its pop-up is shown.
local function show_highlight(a)
  if not (a and vim.api.nvim_buf_is_valid(a.buf)) then return end
  vim.api.nvim_buf_clear_namespace(a.buf, hl_ns, 0, -1)
  local last_text = vim.api.nvim_buf_get_lines(a.buf, a.last - 1, a.last, false)[1] or ''
  vim.api.nvim_buf_set_extmark(a.buf, hl_ns, a.first - 1, math.max(0, a.first_col - 1), {
    end_row = a.last - 1,
    end_col = math.min(math.max(a.last_col, 0), #last_text),
    hl_group = 'ButwhyHighlight',
    priority = 200, -- above treesitter and LSP semantic tokens
  })
end

local function clear_highlight(a)
  if a and vim.api.nvim_buf_is_valid(a.buf) then vim.api.nvim_buf_clear_namespace(a.buf, hl_ns, 0, -1) end
end

-- Same colours as the flash from vim.hl.on_yank() (IncSearch; orange background in many themes).
local function set_hl() vim.api.nvim_set_hl(0, 'ButwhyHighlight', { link = 'IncSearch', default = true }) end

---Resize a floating pop-up to its visible text: as wide as the longest line (wrapping at
---max_width) and as tall as the lines it displays, placed next to the highlight. The title
---shows the drill-down level.
local function fit(chat)
  local win = chat.ui.winnr
  if not (win and vim.api.nvim_win_is_valid(win)) or vim.api.nvim_win_get_config(win).relative == '' then return end
  local hidden = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines then hidden[m[2]] = true end
  end
  local longest = 0
  for i, line in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    if not hidden[i - 1] then longest = math.max(longest, vim.fn.strdisplaywidth(line)) end
  end
  local width = math.max(MIN_WIDTH, math.min(longest + 1, M.max_width, vim.o.columns - 4))
  -- Set the width first: how many screen lines the text wraps to depends on it.
  vim.api.nvim_win_set_config(win, { width = width, height = 1 })
  local height = math.max(1, math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 6))
  local st = states[chat.bufnr]
  local pos = place(st and st.anchor, width, height)
  local config = { relative = 'editor', width = width, height = height, row = pos.row, col = pos.col }
  if st then config.title = st.level > 0 and string.format(' butwhy · level %d ', st.level) or st.title end
  vim.api.nvim_win_set_config(win, config)
end

---Open a chat in a pop-up beside the highlight that shows only the conversation's visible part.
---kind 'explain' sends the explain prompt at once; kind 'ask' sends nothing until the reader
---types a question. Prompts go as hidden messages; the chat stays a normal CodeCompanion chat, so
---follow-up questions work.
local function open_popup(kind, context)
  local tags = require 'codecompanion.interactions.shared.tags'
  local prompts = require 'butwhy.prompts'
  local title = kind == 'ask' and ' butwhy · ask ' or (M.window.title or ' butwhy ')

  local adapter = M.adapter and require('codecompanion.adapters').resolve(M.adapter.name, { model = M.adapter.model })
  local chat = require('codecompanion.interactions.chat').new {
    adapter = adapter,
    buffer_context = context,
    callbacks = require('codecompanion.interactions.shared.rules.helpers').add_callbacks({ callbacks = {} }, { 'butwhy' }),
    from_prompt_library = true,
    ignore_system_prompt = true,
    messages = {
      { role = 'system', content = prompts.render('system', context), opts = { visible = false, _meta = { tag = tags.FROM_CUSTOM_PROMPT } } },
    },
    stop_context_insertion = true,
    window_opts = vim.tbl_extend('force', M.window, { title = title }),
  }
  if not chat then return end

  local anchor = {
    win = context.winnr,
    buf = context.bufnr,
    first = context.start_line,
    last = context.end_line,
    first_col = context.start_col,
    last_col = context.end_col,
  }
  local st = { chat = chat, kind = kind, title = title, anchor = anchor, level = 0, hide_before = 0, asked = false }
  states[chat.bufnr] = st
  last_popup = chat.bufnr
  show_highlight(anchor)
  if M.keys.simpler then
    vim.keymap.set('n', M.keys.simpler, function() M.simpler(chat.bufnr) end, { buffer = chat.bufnr, desc = 'butwhy: explain one level simpler' })
  end

  local pending = false
  local function refresh()
    if pending then return end
    pending = true
    vim.schedule(function()
      pending = false
      if not vim.api.nvim_buf_is_valid(chat.bufnr) then return end
      conceal_plumbing(chat)
      show_hint(chat)
      fit(chat)
    end)
  end
  vim.api.nvim_buf_attach(chat.bufnr, false, { on_lines = refresh })
  -- The cursor's line is shown even when concealed, so moving it can change the height.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, { buffer = chat.bufnr, callback = refresh })
  -- CodeCompanion opens a new window each time the chat is shown again.
  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = chat.bufnr,
    callback = function()
      show_highlight(anchor)
      vim.schedule(function()
        if chat.ui.winnr and vim.api.nvim_win_is_valid(chat.ui.winnr) then style(chat.ui.winnr) end
        refresh()
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWipeout' }, { buffer = chat.bufnr, callback = function() clear_highlight(anchor) end })
  -- Keep the pop-up next to the highlight if the source window scrolls or the editor resizes.
  local follow = vim.api.nvim_create_augroup('butwhy.follow.' .. chat.bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'VimResized' }, { group = follow, callback = refresh })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = chat.bufnr,
    callback = function()
      states[chat.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, follow)
    end,
  })
  style(chat.ui.winnr)
  conceal_plumbing(chat)
  show_hint(chat)
  fit(chat)

  -- Added after creation so the background (attached when the chat is created) precedes it.
  chat:add_message({ role = 'user', content = prompts.render(kind, context) }, { visible = false })
  if kind == 'explain' then
    chat:submit { auto_submit = true }
  else
    chat:add_callback('on_submitted', function() st.asked = true end)
    vim.schedule(function()
      local win = chat.ui.winnr
      if not (win and vim.api.nvim_win_is_valid(win)) then return end
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(chat.bufnr), 0 })
      -- Queued as a keypress: :startinsert from a scheduled callback is not reliably honoured.
      vim.api.nvim_feedkeys('A', 'n', false)
    end)
  end
  return chat
end

---Re-explain the highlight one level simpler, in the pop-up whose chat buffer is `bufnr`
---(default: the current buffer, else the most recent pop-up). The pop-up then shows only the
---new answer.
function M.simpler(bufnr)
  local st = states[bufnr or vim.api.nvim_get_current_buf()] or states[last_popup]
  if not st then return vim.notify('butwhy: no explanation to simplify', vim.log.levels.WARN) end
  local chat = st.chat
  if chat.current_request then return vim.notify('butwhy: still answering', vim.log.levels.INFO) end
  st.level = st.level + 1
  st.hide_before = vim.api.nvim_buf_line_count(chat.bufnr)
  chat:add_message({ role = 'user', content = string.format(SIMPLER, st.level) }, { visible = false })
  conceal_plumbing(chat)
  fit(chat)
  chat:submit { auto_submit = true }
end

local function run(kind, cmd_opts) open_popup(kind, get_context(cmd_opts)) end

function M.setup(opts)
  opts = vim.tbl_extend('force', defaults, opts or {})
  local config = require 'codecompanion.config'

  local adapter = opts.adapter
  M.adapter = type(adapter) == 'string' and { name = adapter } or adapter or nil
  M.window = opts.window
  M.max_width = opts.max_width

  set_hl()
  vim.api.nvim_create_autocmd('ColorScheme', { group = vim.api.nvim_create_augroup('butwhy.hl', { clear = true }), callback = set_hl })

  if config.adapters.http.ollama_cloud == nil then config.adapters.http.ollama_cloud = ollama_cloud end
  if config.adapters.http.mercury == nil then config.adapters.http.mercury = mercury end

  -- Not autoloaded: only butwhy's pop-ups attach this group, so coding chats stay clean.
  config.rules.butwhy = {
    description = 'Reader background for butwhy explanations',
    files = { opts.background },
  }

  vim.api.nvim_create_user_command('ButwhyExplain', function(o) run('explain', o) end, { range = true, desc = 'butwhy: explain selection' })
  vim.api.nvim_create_user_command('ButwhyAsk', function(o) run('ask', o) end, { range = true, desc = 'butwhy: ask about selection' })

  -- Through `:` rather than a Lua call, so the '< and '> marks are set before the prompt
  -- reads the selection.
  local keys = opts.keymaps and vim.tbl_extend('force', defaults.keymaps, opts.keymaps) or {}
  M.keys = keys -- `simpler` is mapped per pop-up, in the chat buffer
  vim.api.nvim_create_user_command('ButwhySimpler', function() M.simpler() end, { desc = 'butwhy: explain one level simpler' })
  if keys.explain then vim.keymap.set('x', keys.explain, ':ButwhyExplain<CR>', { silent = true, desc = 'butwhy: explain selection' }) end
  if keys.ask then vim.keymap.set('x', keys.ask, ':ButwhyAsk<CR>', { silent = true, desc = 'butwhy: ask about selection' }) end
end

return M
