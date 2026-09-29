-- butwhy: explain a highlighted passage at the reader's level, on top of CodeCompanion.
-- Call setup() after require('codecompanion').setup().
local M = {}

local defaults = {
  -- Reader background, attached to every butwhy chat as a CodeCompanion rules group.
  background = '~/.config/butwhy/background.md',
  -- Any CodeCompanion adapter: a name, { name = ..., model = ... }, or false to use the
  -- chat adapter configured in CodeCompanion.
  adapter = { name = 'mercury', model = 'mercury-2.5' },
  -- The answer pop-up: any CodeCompanion chat window options, applied to butwhy chats only.
  window = { layout = 'float', width = 0.6, height = 0.6, border = 'rounded', title = ' butwhy ' },
}

local ns = vim.api.nvim_create_namespace 'butwhy.popup'

-- prompts/ sits two levels above this file: <root>/lua/butwhy/init.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
M.prompt_dir = root .. '/prompts'

-- Mercury (Inception Labs) speaks the OpenAI chat format. Registered only if the user has no
-- adapter of that name, so the default adapter works without extra configuration.
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

---Look up a butwhy prompt and attach the configured adapter, leaving the cached prompt untouched.
---@param alias string
---@param context CodeCompanion.BufferContext
---@return table|nil
function M.resolve_item(alias, context)
  local item = require('codecompanion.action_palette').resolve_from_alias(alias, context)
  if not item then return nil end
  item = vim.tbl_extend('force', {}, item)
  item.opts = vim.tbl_extend('force', {}, item.opts or {}, { adapter = M.adapter })
  return item
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
  local in_context, prev_hidden = false, true
  for i, line in ipairs(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)) do
    in_context = line == '> Context:' or (in_context and line:match '^> ' ~= nil)
    local hide = headers[vim.trim(line)] or in_context or (prev_hidden and vim.trim(line) == '')
    if hide then vim.api.nvim_buf_set_extmark(chat.bufnr, ns, i - 1, 0, { conceal_lines = '' }) end
    prev_hidden = hide
  end
end

---Open a chat in the pop-up window that shows only the model's answers. The prompt is sent as
---hidden messages; the chat stays a normal CodeCompanion chat, so follow-ups work.
local function open_popup(item, context)
  local tags = require 'codecompanion.interactions.shared.tags'
  local prompts = vim.deepcopy(item.prompts)
  require('codecompanion.prompt_library.markdown').resolve_placeholders({ prompts = prompts, path = item.path }, context)

  local system, user = {}, {}
  for _, p in ipairs(prompts) do
    table.insert(p.role == 'system' and system or user, p.content)
  end

  local adapter = M.adapter and require('codecompanion.adapters').resolve(M.adapter.name, { model = M.adapter.model })
  local chat = require('codecompanion.interactions.chat').new {
    adapter = adapter,
    buffer_context = context,
    callbacks = require('codecompanion.interactions.shared.rules.helpers').add_callbacks({ callbacks = {} }, item.rules),
    from_prompt_library = true,
    ignore_system_prompt = true,
    messages = {
      { role = 'system', content = table.concat(system, '\n\n'), opts = { visible = false, _meta = { tag = tags.FROM_CUSTOM_PROMPT } } },
    },
    stop_context_insertion = true,
    window_opts = M.window,
  }
  if not chat then return end

  vim.wo[chat.ui.winnr].conceallevel = 2
  local pending = false
  vim.api.nvim_buf_attach(chat.bufnr, false, {
    on_lines = function()
      if pending then return end
      pending = true
      vim.schedule(function()
        pending = false
        if vim.api.nvim_buf_is_valid(chat.bufnr) then conceal_plumbing(chat) end
      end)
    end,
  })
  conceal_plumbing(chat)

  -- Added after creation so the background (attached when the chat is created) precedes it.
  chat:add_message({ role = 'user', content = table.concat(user, '\n\n') }, { visible = false })
  chat:submit { auto_submit = true }
  return chat
end

local function run(alias, cmd_opts)
  local context = get_context(cmd_opts)
  local item = M.resolve_item(alias, context)
  if not item then return vim.notify('butwhy: prompt ' .. alias .. ' not found', vim.log.levels.ERROR) end
  open_popup(item, context)
end

function M.setup(opts)
  opts = vim.tbl_extend('force', defaults, opts or {})
  local config = require 'codecompanion.config'

  local adapter = opts.adapter
  M.adapter = type(adapter) == 'string' and { name = adapter } or adapter or nil
  M.window = opts.window

  if config.adapters.http.mercury == nil then config.adapters.http.mercury = mercury end

  -- Not autoloaded: only the butwhy prompts name this group, so coding chats stay clean.
  config.rules.butwhy = {
    description = 'Reader background for butwhy explanations',
    files = { opts.background },
  }

  local dirs = config.prompt_library.markdown.dirs
  if not vim.tbl_contains(dirs, M.prompt_dir) then table.insert(dirs, M.prompt_dir) end

  vim.api.nvim_create_user_command('ButwhyExplain', function(o) run('butwhy_explain', o) end, { range = true, desc = 'butwhy: explain selection' })

  -- Through `:` rather than a Lua call, so the '< and '> marks are set before the prompt
  -- reads the selection.
  vim.keymap.set('x', '<leader>we', ':ButwhyExplain<CR>', { silent = true, desc = 'butwhy: explain selection' })
end

return M
