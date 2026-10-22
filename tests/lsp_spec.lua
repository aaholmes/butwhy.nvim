-- Checks for the LSP related-text provider, using an in-process fake language server. Run from
-- the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/lsp_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq
local related = require 'butwhy.related'

-- A project: main.py (200 lines; the highlight is lines 100-101) and other.py.
local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, 'p')
local main_lines = {}
for i = 1, 200 do
  main_lines[i] = 'line ' .. i
end
main_lines[10] = 'far_def = 1  # defined far above the highlight'
main_lines[100] = 'x = total_value + near_def + far_def'
main_lines[101] = 'y = outside_def(x) + missing'
main_lines[110] = 'near_def = 2'
vim.fn.writefile(main_lines, dir .. '/main.py')
vim.fn.writefile({
  'import math',
  '',
  '# Total value accumulated through this node,',
  '# relative to the side that just moved.',
  'def total_value(node):',
  '    """Sum of rewards."""',
  '    return node.sum',
  '',
  'OTHER = 3',
}, dir .. '/other.py')

local function word_at(params)
  local path = vim.uri_to_fname(params.textDocument.uri)
  local line = vim.fn.readfile(path)[params.position.line + 1]
  local col = vim.str_byteindex(line, 'utf-16', params.position.character)
  return line:sub(col + 1):match '^[%w_]+'
end

local function loc(path, line)
  return { uri = vim.uri_from_fname(path), range = { start = { line = line - 1, character = 0 }, ['end'] = { line = line - 1, character = 3 } } }
end

local DEFS = {
  total_value = loc(dir .. '/other.py', 5),
  near_def = loc(dir .. '/main.py', 110),
  far_def = loc(dir .. '/main.py', 10),
  outside_def = loc('/usr/lib/python3/site.py', 1),
}

local requests = 0
local function fake_server(opts)
  return function()
    local closing = false
    return {
      request = function(method, params, callback)
        if method == 'initialize' then
          callback(nil, { capabilities = { definitionProvider = true } })
        elseif method == 'textDocument/definition' then
          requests = requests + 1
          if not opts.silent then vim.schedule(function() callback(nil, DEFS[word_at(params)]) end) end
        else
          callback(nil, nil)
        end
        return true, requests
      end,
      notify = function() return true end,
      is_closing = function() return closing end,
      terminate = function() closing = true end,
    }
  end
end

local function open_main(server_opts)
  vim.cmd 'silent! %bwipeout!'
  vim.cmd.edit(dir .. '/main.py')
  local buf = vim.api.nvim_get_current_buf()
  if server_opts then
    -- A distinct name per behaviour: vim.lsp.start reuses a client with the same name and root.
    local id = vim.lsp.start({ name = server_opts.silent and 'fake_silent' or 'fake', cmd = fake_server(server_opts), root_dir = dir }, { bufnr = buf })
    vim.wait(2000, function() return vim.lsp.get_client_by_id(id).initialized end, 10)
  end
  return { bufnr = buf, start_line = 100, end_line = 101 }
end

local function sources(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = e.source
  end
  return table.concat(out, ' | ')
end

check('a definition in another project file is included with its comments and body', function()
  local entries = related.lsp(open_main {})
  local e = entries[1]
  assert(e, 'no entries')
  eq(e.source, 'other.py:3-7 (definition of total_value)', 'source')
  assert(e.text:find('# Total value accumulated', 1, true), 'leading comment missing:\n' .. e.text)
  assert(e.text:find('def total_value(node):', 1, true), 'declaration missing:\n' .. e.text)
  assert(e.text:find('Sum of rewards', 1, true), 'docstring missing:\n' .. e.text)
  assert(not e.text:find('import math', 1, true) and not e.text:find('OTHER', 1, true), 'unrelated lines included:\n' .. e.text)
end)

check('a same-file definition inside the surroundings is skipped; one outside is kept', function()
  local s = sources(related.lsp(open_main {}))
  assert(not s:find('near_def', 1, true), 'near definition included: ' .. s)
  assert(s:find('main.py:10-10 (definition of far_def)', 1, true), 'far definition missing: ' .. s)
end)

check('definitions outside the project are skipped', function()
  local s = sources(related.lsp(open_main {}))
  assert(not s:find('outside_def', 1, true), 'library definition included: ' .. s)
end)

check('entries follow the order of first appearance in the highlight', function()
  eq(sources(related.lsp(open_main {})), 'other.py:3-7 (definition of total_value) | main.py:10-10 (definition of far_def)', 'order')
end)

check('each symbol is asked about once', function()
  local ctx = open_main {}
  requests = 0
  related.lsp(ctx)
  -- x, total_value, near_def, far_def, y, outside_def, missing
  eq(requests, 7, 'definition requests')
end)

check('max_entries caps the number of entries', function()
  eq(#related.lsp(open_main {}, { max_entries = 1 }), 1, 'entries')
end)

check('without a language server it returns nothing', function()
  local entries = related.lsp(open_main(nil))
  eq(#entries, 0, 'entries')
end)

check('a server that never answers costs at most the timeout', function()
  local ctx = open_main { silent = true }
  local t0 = vim.uv.hrtime()
  local entries = related.lsp(ctx, { timeout_ms = 200 })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  eq(#entries, 0, 'entries')
  assert(ms < 400, string.format('took %.0f ms', ms))
end)

check('a definition whose body ends with a closing brace keeps the brace', function()
  local lines = { 'impl V {', '    /// Dot product.', '    pub fn dot(&self, o: &V) -> f64 {', '        self.x * o.x', '    }', '', '    pub fn other() {}', '}' }
  local first, last = related._excerpt(lines, 3, 12)
  eq(first, 2, 'first line')
  eq(last, 5, 'last line')
end)

check('a definition does not run into the next item at the same indent', function()
  local lines = { 'struct N {', '    /// Visits.', '    pub visits: u32,', '    /// Total.', '    pub total: f64,', '}' }
  local first, last = related._excerpt(lines, 3, 12)
  eq(first, 2, 'first line')
  eq(last, 3, 'last line')
end)

-- End to end: setup { related = 'lsp' } sends the definitions to the model.
local server = dofile(root .. '/tests/mock_llm.lua').start { { 'Answer.' } }
local config = require 'codecompanion.config'
config.adapters.http.mock = function()
  return require('codecompanion.adapters').extend('openai_compatible', {
    env = { url = 'http://127.0.0.1:' .. server.port, chat_url = '/v1/chat/completions', api_key = 'HOME' },
    schema = { model = { default = 'mock-model' } },
  })
end
local done = 0
vim.api.nvim_create_autocmd('User', { pattern = 'CodeCompanionChatDone', callback = function() done = done + 1 end })

check("setup { related = 'lsp' } sends definitions to the model", function()
  require('butwhy').setup { adapter = 'mock', background = root .. '/tests/fixtures/background.md', related = 'lsp' }
  open_main {}
  vim.cmd '100,101ButwhyExplain'
  vim.wait(5000, function() return done >= 1 and #server.requests >= 1 end, 20)
  local body = vim.json.encode(server.requests[1].messages)
  assert(body:find('definition of total_value', 1, true) and body:find('Sum of rewards', 1, true), 'definition not sent')
end)

check("setup rejects an unknown related provider name", function()
  local ok, err = pcall(require('butwhy').setup, { background = root .. '/tests/fixtures/background.md', related = 'wikipedia' })
  assert(not ok and tostring(err):find('related', 1, true), 'expected an error naming related, got: ' .. tostring(err))
end)

h.finish()
