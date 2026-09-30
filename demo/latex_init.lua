-- demo/init.lua plus LaTeX rendering, for recording docs/latex.gif in kitty (see
-- demo/record_latex.sh). snacks.nvim draws each $...$ as an image through kitty's graphics
-- protocol; it needs tectonic or pdflatex, ImageMagick and the treesitter latex parser.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
dofile(root .. '/demo/init.lua')
vim.cmd.packadd 'snacks.nvim'

-- Inline equations: typeset with a fixed-height phantom and trim only the sides, so every one is
-- drawn at the same scale; display equations: display style without display maths' blank space.
require('snacks').setup {
  image = {
    enabled = true,
    convert = { magick = { math = { '-density', 192, '{src}[{page}]', '-define', 'trim:edges=east,west', '-trim' } } },
    math = { latex = { font_size = 'large' } },
  },
}
local doc = require 'snacks.image.doc'
local latex = doc.transforms.latex
doc.transforms.latex = function(img, ctx)
  local src = vim.trim(img.content or '')
  local inline = (src:find '^%$' and not src:find '^%$%$') or src:find '^\\%('
  latex(img, ctx)
  if img.content then
    local prefix = inline and '\\vphantom{(_f}' or '\\displaystyle '
    img.content = img.content:gsub('\\%[(.-)\\%]', function(m) return '\\(' .. prefix .. m .. '\\)' end, 1)
  end
end

-- An inline equation gets one row and as many columns as its aspect ratio needs, without the
-- two padding cells snacks adds (otherwise tall ones are drawn below the line, or shrunk).
local Placement, util = require 'snacks.image.placement', require 'snacks.image.util'
local state = Placement.state
local function inline(self)
  local pos = self.opts.pos or { 1, 0 }
  local r = self.opts.range or { pos[1], pos[2], pos[1], pos[2] }
  if r[1] ~= r[3] then return false end
  local line = vim.api.nvim_buf_get_lines(self.buf, r[1] - 1, r[1], false)[1] or ''
  return line:sub(1, r[2]):find '%S' ~= nil or line:sub(r[4] + 1):find '%S' ~= nil
end
function Placement:state()
  local fit, fitted = util.fit, nil
  util.fit = function(file, cells, opts)
    local size = fit(file, cells, opts)
    if inline(self) then
      local px = opts and opts.info and opts.info.size or util.dim(file)
      local term = Snacks.image.terminal.size()
      size = { width = math.max(1, math.min(math.ceil(px.width / px.height * term.cell_height / term.cell_width), cells.width)), height = 1 }
    end
    fitted = { width = size.width, height = size.height }
    return size
  end
  local ok, st = pcall(state, self)
  util.fit = fit
  if not ok then error(st, 0) end
  if fitted and st.loc.height == 1 and st.loc.width == math.ceil(fitted.width / fitted.height) + 2 then
    st.loc.width = st.loc.width - 2
  end
  return st
end

-- Compile with pdflatex rather than tectonic, which snacks tries first: 0.13 s per equation
-- instead of 0.4 s, so answers show raw LaTeX for less time. The template needs the standalone,
-- preview and varwidth packages. snacks keeps its converter list private; reach it through upvalues.
do
  local function upvalue(fn, name)
    for i = 1, math.huge do
      local n, v = debug.getupvalue(fn, i)
      if not n then return end
      if n == name then return v end
    end
  end
  local Convert = upvalue(require('snacks.image.convert').convert, 'Convert')
  local commands = Convert and upvalue(Convert._resolve, 'commands')
  local cmds = commands and commands.tex and commands.tex.cmd
  if cmds and vim.fn.executable 'pdflatex' == 1 then
    for i, c in ipairs(cmds) do
      if c.cmd == 'pdflatex' then table.insert(cmds, 1, table.remove(cmds, i)) break end
    end
  end
end

-- snacks hides each equation's source with conceal extmarks, honoured only when conceallevel > 0.
-- concealcursor keeps the selected equation drawn while the cursor is on it (Normal and Visual).
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  callback = function()
    vim.opt_local.conceallevel, vim.opt_local.concealcursor, vim.opt_local.linebreak = 2, 'nv', true
  end,
})
