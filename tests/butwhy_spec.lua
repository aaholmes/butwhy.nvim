-- Headless checks, run from the repo root:
--   nvim --headless -u tests/minimal_init.lua -c 'luafile tests/butwhy_spec.lua'
-- Exits 0 if every check passes, 1 otherwise. Sends no requests to any model.

local failures, passes = 0, 0

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passes = passes + 1
    io.write("ok    ", name, "\n")
  else
    failures = failures + 1
    io.write("FAIL  ", name, "\n      ", tostring(err), "\n")
  end
end

local function eq(got, want, what)
  if got ~= want then
    error(string.format("%s: got %s, want %s", what or "value", vim.inspect(got), vim.inspect(want)), 2)
  end
end

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
local prompt_dir = root .. "/prompts"

-- A 200-line scratch buffer standing in for the file being read.
local buf = vim.api.nvim_create_buf(true, false)
local lines = {}
for i = 1, 200 do
  lines[i] = "line " .. i
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_buf_set_name(buf, "/tmp/butwhy_fixture.py")

local function ctx(first, last)
  return {
    bufnr = buf,
    filetype = "python",
    mode = "v",
    is_visual = true,
    start_line = first,
    end_line = last,
    code = table.concat(vim.list_slice(lines, first, last), "\n"),
  }
end

check("butwhy loads from this repo", function()
  local path = vim.fs.normalize(vim.api.nvim_get_runtime_file("lua/butwhy/init.lua", false)[1] or "")
  eq(path, root .. "/lua/butwhy/init.lua", "module path")
end)

check("helper: 40 lines each side of the highlight", function()
  local helper = dofile(prompt_dir .. "/butwhy.lua")
  local out = vim.split(helper.surrounding({ context = ctx(100, 101) }), "\n")
  eq(out[1], "line 60", "first line")
  eq(out[#out], "line 141", "last line")
  eq(#out, 82, "line count")
end)

check("helper: clamps at the start and end of the buffer", function()
  local helper = dofile(prompt_dir .. "/butwhy.lua")
  local head = vim.split(helper.surrounding({ context = ctx(3, 3) }), "\n")
  eq(head[1], "line 1", "first line near start")
  local tail = vim.split(helper.surrounding({ context = ctx(195, 200) }), "\n")
  eq(tail[#tail], "line 200", "last line near end")
end)

check("helper: filename is the basename", function()
  local helper = dofile(prompt_dir .. "/butwhy.lua")
  eq(helper.filename({ context = ctx(1, 1) }), "butwhy_fixture.py", "filename")
end)

check("explain.md parses as a chat prompt with the butwhy rules group", function()
  local md = require("codecompanion.prompt_library.markdown")
  local item = assert(md.parse_file(prompt_dir .. "/explain.md", ctx(100, 101)), "parse_file returned nil")
  eq(item.interaction, "chat", "interaction")
  eq(item.opts.alias, "butwhy_explain", "alias")
  eq(item.opts.auto_submit, true, "auto_submit")
  eq(item.opts.ignore_system_prompt, true, "ignore_system_prompt")
  eq(item.opts.stop_context_insertion, true, "stop_context_insertion")
  assert(vim.tbl_contains(item.rules or {}, "butwhy"), "rules must include butwhy")
  eq(item.prompts[1].role, "system", "first role")
  eq(item.prompts[2].role, "user", "second role")
end)

check("explain.md placeholders all resolve, highlight and surroundings kept separate", function()
  local md = require("codecompanion.prompt_library.markdown")
  local c = ctx(100, 101)
  local item = md.parse_file(prompt_dir .. "/explain.md", c)
  md.resolve_placeholders(item, c)
  local user = item.prompts[2].content
  assert(not user:find("${", 1, true), "unresolved placeholder in:\n" .. user)
  assert(user:find("HIGHLIGHT (lines 100-101)", 1, true), "highlight header missing")
  assert(user:find("line 100\nline 101", 1, true), "highlight text missing")
  assert(user:find("SURROUNDING TEXT", 1, true), "surrounding header missing")
  assert(user:find("line 60", 1, true), "surrounding text missing")
  assert(user:find("butwhy_fixture.py (python)", 1, true), "filename line missing")
end)

check("explain.md names no model or adapter", function()
  local md = require("codecompanion.prompt_library.markdown")
  local item = md.parse_file(prompt_dir .. "/explain.md", ctx(1, 1))
  eq(item.opts.adapter, nil, "adapter in frontmatter")
end)

check("rules group butwhy points at the configured background and is not autoloaded", function()
  local cfg = require("codecompanion.config")
  local group = assert(cfg.rules.butwhy, "rules.butwhy missing")
  eq(vim.fs.normalize(group.files[1]), root .. "/tests/fixtures/background.md", "rules file")
  local autoload = cfg.rules.opts and cfg.rules.opts.chat and cfg.rules.opts.chat.autoload
  autoload = type(autoload) == "table" and autoload or { autoload }
  assert(not vim.tbl_contains(autoload, "butwhy"), "butwhy must not be autoloaded")
end)

check("prompt library scans the plugin's prompts, once", function()
  require("butwhy").setup { background = root .. "/tests/fixtures/background.md" }
  local cfg = require("codecompanion.config")
  local n = 0
  for _, d in ipairs(cfg.prompt_library.markdown.dirs) do
    if vim.fs.normalize(d) == prompt_dir then n = n + 1 end
  end
  eq(n, 1, "copies of the prompt dir")
end)

check("default adapter is Mercury 2.5", function()
  local item = assert(require("butwhy").resolve_item("butwhy_explain", ctx(100, 101)), "alias not found")
  eq(item.opts.adapter.name, "mercury", "adapter")
  eq(item.opts.adapter.model, "mercury-2.5", "model")
end)

check("built-in mercury adapter uses the Inception endpoint", function()
  local adapter = assert(require("codecompanion.adapters").resolve("mercury"), "mercury adapter missing")
  eq(adapter.env.url, "https://api.inceptionlabs.ai", "url")
  eq(adapter.env.chat_url, "/v1/chat/completions", "chat_url")
  eq(adapter.env.api_key, "INCEPTION_API_KEY", "api_key env var")
  eq(adapter.schema.model.default, "mercury-2.5", "model")
end)

check("built-in mercury adapter sends reasoning_effort = instant", function()
  local adapter = require("codecompanion.adapters").resolve("mercury")
  adapter:map_schema_to_params()
  eq(adapter.parameters.reasoning_effort, "instant", "reasoning_effort")
end)

check("a user-defined mercury adapter is not replaced", function()
  local cfg = require("codecompanion.config")
  local mine = function() end
  cfg.adapters.http.mercury = mine
  require("butwhy").setup { background = root .. "/tests/fixtures/background.md" }
  assert(cfg.adapters.http.mercury == mine, "setup overwrote the user's mercury adapter")
end)

check("adapter option switches to any CodeCompanion adapter", function()
  local butwhy = require("butwhy")
  butwhy.setup { adapter = { name = "anthropic", model = "some-model" } }
  local item = butwhy.resolve_item("butwhy_explain", ctx(100, 101))
  eq(item.opts.adapter.name, "anthropic", "adapter")
  eq(item.opts.adapter.model, "some-model", "model")
  butwhy.setup { adapter = "ollama" }
  eq(butwhy.resolve_item("butwhy_explain", ctx(1, 1)).opts.adapter.name, "ollama", "adapter from string")
  butwhy.setup { adapter = false }
  eq(butwhy.resolve_item("butwhy_explain", ctx(1, 1)).opts.adapter, nil, "adapter=false uses the chat default")
end)

check("resolve_item does not mutate the cached prompt", function()
  local butwhy = require("butwhy")
  butwhy.setup { adapter = "ollama" }
  butwhy.resolve_item("butwhy_explain", ctx(1, 1))
  local cached = require("codecompanion.action_palette").resolve_from_alias("butwhy_explain", ctx(1, 1))
  eq(cached.opts.adapter, nil, "cached adapter")
end)

check("<leader>we runs :ButwhyExplain from visual mode", function()
  eq(vim.fn.maparg("<leader>we", "x"), ":ButwhyExplain<CR>", "rhs")
  eq(vim.fn.exists(":ButwhyExplain"), 2, "command exists")
end)

check("keymaps = false sets no keymap, but the command still exists", function()
  pcall(vim.keymap.del, "x", "<leader>we")
  require("butwhy").setup { keymaps = false }
  eq(vim.fn.maparg("<leader>we", "x"), "", "rhs")
  eq(vim.fn.exists(":ButwhyExplain"), 2, "command exists")
end)

check("keymaps.explain rebinds the explain key", function()
  pcall(vim.keymap.del, "x", "<leader>we")
  require("butwhy").setup { keymaps = { explain = "<leader>x" } }
  eq(vim.fn.maparg("<leader>x", "x"), ":ButwhyExplain<CR>", "rhs")
  eq(vim.fn.maparg("<leader>we", "x"), "", "default key")
end)

io.write(string.format("\n%d passed, %d failed\n", passes, failures))
vim.cmd(failures == 0 and "qa!" or "cq!")
