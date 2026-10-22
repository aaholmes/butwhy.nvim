-- Checks for the keyword (BM25) related-text provider, which needs no language server. Run from
-- the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/keyword_spec.lua'
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
local h = dofile(root .. '/tests/harness.lua')
local check, eq = h.check, h.eq
local related = require 'butwhy.related'

-- A buffer of `n` filler paragraphs (3 lines each, blank-separated), with `put` overriding lines.
local function doc(n, put)
  local lines = {}
  for p = 1, n do
    for k = 1, 3 do
      lines[#lines + 1] = string.format('filler paragraph %d sentence %d about nothing much', p, k)
    end
    lines[#lines + 1] = ''
  end
  for lnum, text in pairs(put or {}) do
    lines[lnum] = text
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.md')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function texts(entries)
  return table.concat(vim.tbl_map(function(e) return e.text end, entries), '\n====\n')
end

check('tokens: lowercase words, camelCase and snake_case split, stop words dropped, plurals folded', function()
  eq(table.concat(related._tokens 'The totalValue of snake_case nodes and the Prunes', ' '), 'total value snake case node prune', 'tokens')
end)

check('chunks: paragraphs split at blank lines, long ones cut at max_lines', function()
  local lines = { 'a b', 'c d', '', '', 'e f' }
  for i = 1, 25 do
    lines[#lines + 1] = 'long ' .. i
  end
  local chunks = related._chunks(lines, 10)
  local ranges = vim.tbl_map(function(c) return c.first .. '-' .. c.last end, chunks)
  eq(table.concat(ranges, ','), '1-2,5-14,15-24,25-30', 'chunk ranges')
end)

check('chunks: a docstring or block comment with blank lines inside stays one chunk', function()
  local lines = { '"""Module summary.', '', 'More detail.', '"""', '', 'x = 1', '', '/**', ' * a', '', ' * b', ' */', 'int y;' }
  local ranges = vim.tbl_map(function(c) return c.first .. '-' .. c.last end, related._chunks(lines, 20))
  eq(table.concat(ranges, ','), '1-4,6-6,8-13', 'chunk ranges')
end)

check('an import block is never returned', function()
  local buf = doc(60, {
    [1] = 'from velocity.obstacle import collision_horizon',
    [2] = 'import velocity_obstacle.collision as half_plane',
    [3] = 'use velocity::obstacle::collision;',
    [201] = 'We cut the velocity obstacle with a half-plane at the collision horizon.',
  })
  local entries = related.keyword { bufnr = buf, start_line = 201, end_line = 201 }
  assert(not texts(entries):find('import', 1, true), 'import block returned:\n' .. texts(entries))
end)

check('setup { surrounding = n } sets the window sent and the window keyword search skips', function()
  local buf = doc(60, {
    [190] = 'The velocity obstacle is the set of relative velocities that lead to a collision.',
    [201] = 'We cut the velocity obstacle with a half-plane at the collision horizon.',
  })
  local butwhy, prompts = require 'butwhy', require 'butwhy.prompts'
  butwhy.setup { surrounding = 5 }
  local ctx = { bufnr = buf, start_line = 201, end_line = 201 }
  local sur = prompts.surrounding(ctx)
  eq(#vim.split(sur, '\n'), 11, 'lines in a ±5 window')
  local entries = related.keyword(ctx)
  assert(texts(entries):find('set of relative velocities', 1, true), 'line 190 is outside a ±5 window:\n' .. texts(entries))
  butwhy.setup {}
  eq(#vim.split(prompts.surrounding(ctx), '\n'), 80, 'default ±40: lines 161-240, where the buffer ends')
end)

check('finds a far paragraph that shares rare terms with the highlight', function()
  local buf = doc(60, {
    [9] = 'The velocity obstacle is the set of relative velocities that lead to a collision.',
    [201] = 'We cut the velocity obstacle with a half-plane at the collision horizon.',
  })
  local entries = related.keyword { bufnr = buf, start_line = 201, end_line = 201 }
  assert(#entries >= 1, 'nothing found')
  assert(entries[1].text:find('set of relative velocities', 1, true), 'wrong top entry:\n' .. texts(entries))
  assert(entries[1].source:find(':9%-11'), 'source should give lines 9-11: ' .. entries[1].source)
end)

check('skips text inside the surroundings already sent', function()
  local buf = doc(60, {
    [190] = 'The velocity obstacle is the set of relative velocities that lead to a collision.',
    [201] = 'We cut the velocity obstacle with a half-plane at the collision horizon.',
  })
  local entries = related.keyword { bufnr = buf, start_line = 201, end_line = 201 }
  assert(not texts(entries):find('set of relative velocities', 1, true), 'returned text from the window')
end)

check('returns nothing when no outside paragraph shares two terms with the highlight', function()
  local buf = doc(60, { [201] = 'Quaternion slerp interpolates orientations.' })
  eq(#related.keyword { bufnr = buf, start_line = 201, end_line = 201 }, 0, 'entries')
end)

check('a paragraph matching only stop words or one common term is not returned', function()
  local buf = doc(60, { [201] = 'This is about the filler and it is the thing.' })
  eq(#related.keyword { bufnr = buf, start_line = 201, end_line = 201 }, 0, 'entries')
end)

check('respects max_entries and max_chars, best first', function()
  local put = { [201] = 'Heat bath configuration interaction selects determinants.' }
  for _, l in ipairs { 1, 21, 41, 61 } do
    put[l] = 'heat bath configuration interaction ' .. l
  end
  put[61] = 'heat bath configuration interaction selects determinants 61'
  local buf = doc(60, put)
  local entries = related.keyword({ bufnr = buf, start_line = 201, end_line = 201 }, { max_entries = 2 })
  eq(#entries, 2, 'entries')
  assert(entries[1].text:find('determinants 61', 1, true), 'best match not first:\n' .. texts(entries))
  local small = related.keyword({ bufnr = buf, start_line = 201, end_line = 201 }, { max_chars = 200 })
  local chars = 0
  for _, e in ipairs(small) do
    chars = chars + #e.text
  end
  assert(chars <= 200 and #small >= 1, 'max_chars not respected: ' .. chars)
end)

check('setup accepts a list of providers and drops repeated text', function()
  local butwhy = require 'butwhy'
  butwhy.setup {
    related = {
      function() return { { source = 'a', text = 'one' }, { source = 'b', text = 'two' } } end,
      function() return { { source = 'c', text = 'two' }, { source = 'd', text = 'three' } } end,
    },
  }
  local got = butwhy.related {}
  eq(table.concat(vim.tbl_map(function(e) return e.source end, got), ','), 'a,b,d', 'sources')
  butwhy.setup { related = { 'lsp', 'keyword' } }
  eq(type(butwhy.related), 'function', 'combined provider')
  local ok = pcall(butwhy.setup, { related = { 'nope' } })
  assert(not ok, 'unknown provider name accepted')
end)

check('timing: a 6000-line buffer is searched in under 100 ms', function()
  local buf = doc(1500, { [3001] = 'velocity obstacle collision horizon half-plane' })
  local t0 = vim.uv.hrtime()
  related.keyword { bufnr = buf, start_line = 3001, end_line = 3001 }
  local ms = (vim.uv.hrtime() - t0) / 1e6
  io.write(string.format('      (%.1f ms for 6000 lines)\n', ms))
  assert(ms < 100, string.format('%.1f ms', ms))
end)

h.finish()
