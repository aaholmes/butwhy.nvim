-- butwhy: explain a highlighted passage at the reader's level, on top of CodeCompanion.
-- Call setup() after require('codecompanion').setup().
local M = {}

local defaults = {
  -- Reader background, attached to every butwhy chat as a CodeCompanion rules group.
  background = '~/.config/butwhy/background.md',
  -- Any CodeCompanion adapter: a name, { name = ..., model = ... }, or false to use the
  -- chat adapter configured in CodeCompanion.
  adapter = { name = 'mercury', model = 'mercury-2.5' },
}

-- prompts/ sits two levels above this file: <root>/lua/butwhy/init.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
M.prompt_dir = root .. '/prompts'

-- Mercury (Inception Labs) speaks the OpenAI chat format. Registered only if the user has no
-- adapter of that name, so the default adapter works without extra configuration.
local function mercury()
  return require('codecompanion.adapters').extend('openai_compatible', {
    env = {
      url = 'https://api.inceptionlabs.ai',
      chat_url = '/v1/chat/completions',
      api_key = 'INCEPTION_API_KEY',
    },
    schema = { model = { default = 'mercury-2.5' } },
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

local function run(alias, cmd_opts)
  local context = require('codecompanion.utils.context').get(vim.api.nvim_get_current_buf(), cmd_opts)
  local item = M.resolve_item(alias, context)
  if not item then return vim.notify('butwhy: prompt ' .. alias .. ' not found', vim.log.levels.ERROR) end
  require('codecompanion.action_palette').resolve(item, context)
end

function M.setup(opts)
  opts = vim.tbl_extend('force', defaults, opts or {})
  local config = require 'codecompanion.config'

  local adapter = opts.adapter
  M.adapter = type(adapter) == 'string' and { name = adapter } or adapter or nil

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
