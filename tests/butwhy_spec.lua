-- Unit checks, run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/butwhy_spec.lua'
-- Exits 0 if every check passes, 1 otherwise. Sends no requests to any model.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq

local prompts = require 'butwhy.prompts'
require('butwhy').setup { background = root .. '/tests/fixtures/background.md' }

-- A 200-line scratch buffer standing in for the file being read.
local buf = vim.api.nvim_create_buf(true, false)
local lines = {}
for i = 1, 200 do
  lines[i] = 'line ' .. i
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_buf_set_name(buf, '/tmp/butwhy_fixture.py')

local function ctx(first, last)
  return {
    bufnr = buf,
    filetype = 'python',
    start_line = first,
    end_line = last,
    code = table.concat(vim.list_slice(lines, first, last), '\n'),
  }
end

check('butwhy loads from this repo', function()
  local path = vim.fs.normalize(vim.api.nvim_get_runtime_file('lua/butwhy/init.lua', false)[1] or '')
  eq(path, root .. '/lua/butwhy/init.lua', 'module path')
end)

check('surrounding: 40 lines each side of the highlight', function()
  local out = vim.split(prompts.surrounding(ctx(100, 101)), '\n')
  eq(out[1], 'line 60', 'first line')
  eq(out[#out], 'line 141', 'last line')
  eq(#out, 82, 'line count')
end)

check('surrounding: clamps at the start and end of the buffer', function()
  eq(vim.split(prompts.surrounding(ctx(3, 3)), '\n')[1], 'line 1', 'first line near start')
  local tail = vim.split(prompts.surrounding(ctx(195, 200)), '\n')
  eq(tail[#tail], 'line 200', 'last line near end')
end)

check('filename is the basename', function() eq(prompts.filename(ctx(1, 1)), 'butwhy_fixture.py', 'filename') end)

check('prompts render without the yaml treesitter parser or the prompt library', function()
  local real = vim.treesitter.get_string_parser
  vim.treesitter.get_string_parser = function() error 'treesitter must not be used' end
  local ok, out = pcall(prompts.render, 'explain', ctx(100, 101))
  vim.treesitter.get_string_parser = real
  assert(ok, out)
end)

check('system prompt: tutor role, highlight is the topic, a few sentences', function()
  local s = prompts.render('system', ctx(1, 1))
  assert(s:find('HIGHLIGHT is the topic', 1, true), s)
  assert(s:find('few plain sentences', 1, true), s)
  assert(not s:find('${', 1, true), 'unresolved placeholder')
end)

for _, name in ipairs { 'explain', 'ask' } do
  check(name .. ' prompt: placeholders resolve, highlight and surroundings kept separate', function()
    local user = prompts.render(name, ctx(100, 101))
    assert(not user:find('${', 1, true), 'unresolved placeholder in:\n' .. user)
    assert(user:find('HIGHLIGHT (lines 100-101)', 1, true), 'highlight header missing')
    assert(user:find('line 100\nline 101', 1, true), 'highlight text missing')
    assert(user:find('SURROUNDING TEXT', 1, true), 'surrounding header missing')
    assert(user:find('line 60', 1, true), 'surrounding text missing')
    assert(user:find('butwhy_fixture.py (python)', 1, true), 'filename line missing')
  end)
end

check('a % in the highlighted code survives rendering', function()
  local c = ctx(1, 1)
  c.code = 'x = 5 % 3 -- %d %1'
  assert(prompts.render('explain', c):find('x = 5 % 3 -- %d %1', 1, true), 'code mangled')
end)

check('rules group butwhy points at the configured background and is not autoloaded', function()
  local cfg = require 'codecompanion.config'
  local group = assert(cfg.rules.butwhy, 'rules.butwhy missing')
  eq(vim.fs.normalize(group.files[1]), root .. '/tests/fixtures/background.md', 'rules file')
  local autoload = cfg.rules.opts and cfg.rules.opts.chat and cfg.rules.opts.chat.autoload
  autoload = type(autoload) == 'table' and autoload or { autoload }
  assert(not vim.tbl_contains(autoload, 'butwhy'), 'butwhy must not be autoloaded')
end)

check('default adapter is Gemma 4 31B on Ollama Cloud', function()
  eq(require('butwhy').adapter.name, 'ollama_cloud', 'adapter')
  eq(require('butwhy').adapter.model, 'gemma4:31b', 'model')
end)

check('built-in ollama_cloud adapter uses the Ollama Cloud endpoint', function()
  local adapter = assert(require('codecompanion.adapters').resolve 'ollama_cloud', 'ollama_cloud adapter missing')
  eq(adapter.env.url, 'https://ollama.com', 'url')
  eq(adapter.env.chat_url, '/v1/chat/completions', 'chat_url')
  eq(adapter.env.api_key, 'OLLAMA_API_KEY', 'api_key env var')
  eq(adapter.schema.model.default, 'gemma4:31b', 'model')
end)

check('built-in mercury adapter uses the Inception endpoint', function()
  local adapter = assert(require('codecompanion.adapters').resolve 'mercury', 'mercury adapter missing')
  eq(adapter.env.url, 'https://api.inceptionlabs.ai', 'url')
  eq(adapter.env.chat_url, '/v1/chat/completions', 'chat_url')
  eq(adapter.env.api_key, 'INCEPTION_API_KEY', 'api_key env var')
  eq(adapter.schema.model.default, 'mercury-2.5', 'model')
end)

check('built-in mercury adapter sends reasoning_effort = instant', function()
  local adapter = require('codecompanion.adapters').resolve 'mercury'
  adapter:map_schema_to_params()
  eq(adapter.parameters.reasoning_effort, 'instant', 'reasoning_effort')
end)

for _, name in ipairs { 'mercury', 'ollama_cloud' } do
  check('a user-defined ' .. name .. ' adapter is not replaced', function()
    local cfg = require 'codecompanion.config'
    local mine = function() end
    local before = cfg.adapters.http[name]
    cfg.adapters.http[name] = mine
    require('butwhy').setup { background = root .. '/tests/fixtures/background.md' }
    assert(cfg.adapters.http[name] == mine, "setup overwrote the user's " .. name .. ' adapter')
    cfg.adapters.http[name] = before
  end)
end

check('adapter option accepts a table, a name, or false', function()
  local butwhy = require 'butwhy'
  butwhy.setup { adapter = { name = 'anthropic', model = 'some-model' } }
  eq(butwhy.adapter.name, 'anthropic', 'adapter')
  eq(butwhy.adapter.model, 'some-model', 'model')
  butwhy.setup { adapter = 'ollama' }
  eq(butwhy.adapter.name, 'ollama', 'adapter from string')
  butwhy.setup { adapter = false }
  eq(butwhy.adapter, nil, 'adapter=false uses the chat default')
end)

check('commands exist', function()
  for _, c in ipairs { 'ButwhyExplain', 'ButwhyAsk', 'ButwhySimpler' } do
    eq(vim.fn.exists(':' .. c), 2, c)
  end
end)

check('default keys: <leader>we explains and <leader>wa asks, from visual mode', function()
  require('butwhy').setup { background = root .. '/tests/fixtures/background.md' }
  eq(vim.fn.maparg('<leader>we', 'x'), ':ButwhyExplain<CR>', 'explain')
  eq(vim.fn.maparg('<leader>wa', 'x'), ':ButwhyAsk<CR>', 'ask')
end)

check('keymaps = false sets no keymap, but the commands still exist', function()
  pcall(vim.keymap.del, 'x', '<leader>we')
  pcall(vim.keymap.del, 'x', '<leader>wa')
  require('butwhy').setup { keymaps = false }
  eq(vim.fn.maparg('<leader>we', 'x'), '', 'explain')
  eq(vim.fn.maparg('<leader>wa', 'x'), '', 'ask')
  eq(vim.fn.exists ':ButwhyExplain', 2, 'command exists')
end)

check('keymaps.explain rebinds the explain key', function()
  pcall(vim.keymap.del, 'x', '<leader>we')
  require('butwhy').setup { keymaps = { explain = '<leader>x' } }
  eq(vim.fn.maparg('<leader>x', 'x'), ':ButwhyExplain<CR>', 'rhs')
  eq(vim.fn.maparg('<leader>we', 'x'), '', 'default key')
end)

h.finish()
