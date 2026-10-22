-- Related-text providers: text from outside the surroundings that may help explain the
-- highlight. Each returns a list of { source = ..., text = ... } for prompts.related().
local M = {}

M.defaults = {
  timeout_ms = 500, -- total wait for the language servers, so the pop-up is never held longer
  max_symbols = 15, -- identifiers in the highlight to look up
  max_entries = 4,
  max_lines = 12, -- per definition
  max_chars = 3000, -- all entries together
  chunk_lines = 20, -- longest paragraph keyword search returns in one piece
  -- radius: lines each side of the highlight already sent; default the prompts' surroundings
}

-- Words that are never worth a request.
local KEYWORDS = {}
for w in ([[if else elif for while return let mut fn def class import from as in is not and or
  self Self true false True False None nil local function end then do pub use struct impl enum
  const static match break continue pass with try except finally raise yield async await
  int float bool str char void auto new delete this super where type trait mod crate]]):gmatch '%S+' do
  KEYWORDS[w] = true
end

---Identifiers in lines first..last of buf, in order of first appearance: { name, line, col }
---with 0-based line and byte col.
local function symbols(buf, first, last, max)
  local out, seen = {}, {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(buf, first - 1, last, false)) do
    local init = 1
    while #out < max do
      local s, e = line:find('[%a_][%w_]*', init)
      if not s then break end
      local name = line:sub(s, e)
      if not seen[name] and not KEYWORDS[name] then
        seen[name] = true
        out[#out + 1] = { name = name, line = first + lnum - 2, col = s - 1 }
      end
      init = e + 1
    end
  end
  return out
end

local function file_lines(path)
  local b = vim.fn.bufnr(path)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

-- Resolved, so a symlinked path (e.g. /var and /private/var on macOS) compares equal.
local function real(path) return vim.fs.normalize(vim.uv.fs_realpath(path) or path) end

local function indent(s) return #s:match '^%s*' end

-- Comments, decorators and attributes directly above a definition belong to it.
local function is_preamble(s)
  return s:match '^%s*//' or s:match '^%s*#' or s:match '^%s*%-%-' or s:match '^%s*/%*' or s:match '^%s*%*' or s:match '^%s*@'
end

---The definition at 1-based line `at`: comments above it, the declaration, and the lines indented
---under it (a body or docstring), at most max_lines.
local function excerpt(lines, at, max_lines)
  local first = at
  while first > 1 and lines[first - 1] and lines[first - 1]:match '%S' and is_preamble(lines[first - 1]) do
    first = first - 1
  end
  local last, base = at, indent(lines[at] or '')
  while last < #lines and last - first + 1 < max_lines do
    local nxt = lines[last + 1]
    if not nxt:match '%S' then
      -- A blank line inside an indented body continues it; one after a single-line item ends it.
      local after = lines[last + 2]
      if not (after and after:match '%S' and indent(after) > base) then break end
    elseif indent(nxt) <= base then
      break
    end
    last = last + 1
  end
  -- A closing bracket at the declaration's indent ends a body that was opened on it.
  local nxt = lines[last + 1]
  if last > at and nxt and indent(nxt) == base and nxt:match '^%s*[%)%]}]' then last = last + 1 end
  return first, math.min(last, first + max_lines - 1)
end

local function first_location(result)
  if not result then return nil end
  if result.uri or result.targetUri then result = { result } end
  local r = result[1]
  if not r then return nil end
  return r.targetUri or r.uri, (r.targetSelectionRange or r.range).start.line
end

---Definitions of the identifiers in the highlight, found with the buffer's language servers, that
---lie outside the surroundings and inside the project.
local function options(opts)
  return vim.tbl_extend('force', M.defaults, { radius = require('butwhy.prompts').radius }, opts or {})
end

function M.lsp(context, opts)
  opts = options(opts)
  local buf = context.bufnr
  local clients = vim.tbl_filter(function(c) return c:supports_method('textDocument/definition', buf) end, vim.lsp.get_clients { bufnr = buf })
  if #clients == 0 then return {} end

  local syms = symbols(buf, context.start_line, context.end_line, opts.max_symbols)
  local answers, pending = {}, 0
  for i, sym in ipairs(syms) do
    for _, client in ipairs(clients) do
      local line = vim.api.nvim_buf_get_lines(buf, sym.line, sym.line + 1, false)[1]
      local params = {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = sym.line, character = vim.str_utfindex(line, client.offset_encoding, sym.col, false) },
      }
      local ok = client:request('textDocument/definition', params, function(err, result)
        pending = pending - 1
        if not err and not answers[i] then answers[i] = { result = result, root = client.root_dir } end
      end, buf)
      if ok then pending = pending + 1 end
    end
  end
  vim.wait(opts.timeout_ms, function() return pending <= 0 end, 5)

  local here = real(vim.api.nvim_buf_get_name(buf))
  local lo, hi = context.start_line - opts.radius, context.end_line + opts.radius
  local entries, seen, chars = {}, {}, 0
  for i, sym in ipairs(syms) do
    local a = answers[i]
    local uri, line0 = first_location(a and a.result)
    if uri and #entries < opts.max_entries then
      local path = real(vim.uri_to_fname(uri))
      local at = line0 + 1
      local root = a.root and real(a.root)
      local in_project = root and (path == root or vim.startswith(path, root .. '/'))
      local nearby = path == here and at >= lo and at <= hi
      local lines = in_project and not nearby and not seen[path .. ':' .. at] and file_lines(path)
      if lines and lines[at] then
        seen[path .. ':' .. at] = true
        local first, last = excerpt(lines, at, opts.max_lines)
        local text = table.concat(vim.list_slice(lines, first, last), '\n')
        if chars + #text <= opts.max_chars then
          chars = chars + #text
          local rel = vim.fs.relpath(root, path) or vim.fn.fnamemodify(path, ':.')
          entries[#entries + 1] = { source = string.format('%s:%d-%d (definition of %s)', rel, first, last, sym.name), text = text }
        end
      end
    end
  end
  return entries
end

-- Keyword search: BM25 over the buffer's paragraphs, for text with no language server.

local STOP = {}
for w in ([[a an the and or but if then else of to in on at by for with from as is are was were be
  been being it its this that these those there here we you they he she i our your their his her
  not no so than too very can could would should will shall may might must do does did done has
  have had about into over under after before between also just only such each all any some more
  most other which who whom what when where why how one two use used using]]):gmatch '%S+' do
  STOP[w] = true
end
for w in pairs(KEYWORDS) do
  STOP[w:lower()] = true
end

---Search terms in a string: lowercase words (camelCase and snake_case split), without stop words,
---with plurals folded to the singular.
local function tokens(s)
  local out = {}
  for w in s:gsub('(%l)(%u)', '%1 %2'):lower():gmatch '%a[%a%d]*' do
    if #w >= 2 and not STOP[w] then
      if #w > 4 and w:sub(-3) == 'ies' then
        w = w:sub(1, -4) .. 'y'
      elseif #w > 3 and w:sub(-1) == 's' and not w:match '[sui]s$' then
        w = w:sub(1, -2)
      end
      out[#out + 1] = w
    end
  end
  return out
end

-- Whether a line leaves a docstring or block comment open: the closing delimiter of `open` (a
-- docstring quote or '/*') when it is open after this line, else nil.
local function block_after(line, open)
  for _, q in ipairs { '"""', "'''" } do
    local _, n = line:gsub(q, '')
    if (open == q) ~= (n % 2 == 1) then return q end
    if open == q or n > 0 then return nil end
  end
  if open == '/*' then return not line:find('*/', 1, true) and '/*' or nil end
  local last_open = line:match '.*()/%*'
  if last_open and not line:find('*/', last_open, true) then return '/*' end
end

---Paragraphs (runs of non-blank lines, with a docstring or block comment kept whole across blank
---lines), each cut into pieces of at most max_lines: { first, last }.
local function chunks(lines, max_lines)
  local out, start, open = {}, nil, nil
  for i = 1, #lines + 1 do
    local line = lines[i]
    local blank = not (line and line:match '%S') and not (line and open)
    if not blank and not start then start = i end
    if line then open = block_after(line, open) end
    if start and (blank or i - start + 1 == max_lines) then
      out[#out + 1] = { first = start, last = blank and i - 1 or i }
      start = nil
    end
  end
  return out
end

-- Import lines and lone closing brackets: never worth sending.
local function is_import(s)
  return s:match '^%s*import%s' or s:match '^%s*from%s+%S+%s+import' or s:match '^%s*use%s' or s:match '^%s*#%s*include'
    or s:match 'require%s*%(?[\'"]' or s:match '^%s*\\usepackage' or s:match '^%s*[%)}]?;?%s*$'
end

---Paragraphs of the buffer, outside the surroundings, that best match the highlight's words
---(BM25). A paragraph must share at least two distinct terms with the highlight (or its one term).
function M.keyword(context, opts)
  opts = options(opts)
  local buf = context.bufnr
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local query, seen = {}, {}
  for _, line in ipairs(vim.list_slice(lines, context.start_line, context.end_line)) do
    for _, t in ipairs(tokens(line)) do
      if not seen[t] then
        seen[t] = true
        query[#query + 1] = t
      end
    end
  end
  if #query == 0 then return {} end

  local docs, df, total = {}, {}, 0
  for _, d in ipairs(chunks(lines, opts.chunk_lines)) do
    local useful = false
    for i = d.first, d.last do
      useful = useful or not is_import(lines[i])
    end
    if useful then docs[#docs + 1] = d end
  end
  if #docs == 0 then return {} end
  for _, d in ipairs(docs) do
    d.tf, d.len = {}, 0
    for i = d.first, d.last do
      for _, t in ipairs(tokens(lines[i])) do
        d.tf[t] = (d.tf[t] or 0) + 1
        d.len = d.len + 1
      end
    end
    for t in pairs(d.tf) do
      df[t] = (df[t] or 0) + 1
    end
    total = total + d.len
  end
  local n, avg = #docs, math.max(total / #docs, 1)
  local k1, b = 1.2, 0.75
  local lo, hi = context.start_line - opts.radius, context.end_line + opts.radius
  local need = math.min(2, #query)
  local hits = {}
  for _, d in ipairs(docs) do
    if d.last < lo or d.first > hi then
      local score, matched = 0, 0
      for _, q in ipairs(query) do
        local tf = d.tf[q]
        if tf then
          matched = matched + 1
          local idf = math.log(1 + (n - df[q] + 0.5) / (df[q] + 0.5))
          score = score + idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * d.len / avg))
        end
      end
      if matched >= need then hits[#hits + 1] = { d = d, score = score } end
    end
  end
  table.sort(hits, function(x, y) return x.score > y.score end)

  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t')
  local entries, chars = {}, 0
  for _, hit in ipairs(hits) do
    if #entries >= opts.max_entries then break end
    local text = table.concat(vim.list_slice(lines, hit.d.first, hit.d.last), '\n')
    if chars + #text <= opts.max_chars then
      chars = chars + #text
      entries[#entries + 1] = { source = string.format('%s:%d-%d (keyword match)', name, hit.d.first, hit.d.last), text = text }
    end
  end
  return entries
end

M.providers = { lsp = M.lsp, keyword = M.keyword }
M._excerpt = excerpt -- for tests
M._tokens = tokens
M._chunks = chunks

return M
