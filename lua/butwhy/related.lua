-- Related-text providers: text from outside the surroundings that may help explain the
-- highlight. Each returns a list of { source = ..., text = ... } for prompts.related().
local M = {}

M.defaults = {
  timeout_ms = 500, -- total wait for the language servers, so the pop-up is never held longer
  max_symbols = 15, -- identifiers in the highlight to look up
  max_entries = 4,
  max_lines = 12, -- per definition
  max_chars = 3000, -- all entries together
  radius = 40, -- lines each side of the highlight already sent as surroundings
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
function M.lsp(context, opts)
  opts = vim.tbl_extend('force', M.defaults, opts or {})
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

M.providers = { lsp = M.lsp }
M._excerpt = excerpt -- for tests

return M
