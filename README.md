# butwhy.nvim

Highlight a passage in Neovim, such as a line of code, a paragraph or a LaTeX equation, and get it
explained at your level in a chat beside the file. The highlight is the topic; about 40 lines on
either side are sent as context only, so the answer stays on what you selected.

butwhy is built on [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim), a
Neovim plugin that connects chat buffers to large language model (LLM) providers, so it works
with any model CodeCompanion supports.

**Status:** early. Explaining a highlight works. Planned next: re-explain one level simpler
(repeatable, to drill down), free-form questions about a highlight, and web search for further
reading.

## Requirements

- Neovim 0.12 and CodeCompanion v19 (tested with 0.12.4 and v19.22)
- The treesitter `yaml` parser, which CodeCompanion uses to read Markdown prompts
- An API key for the model you choose, or a local model server

## Install

With the built-in `vim.pack`:

```lua
vim.pack.add {
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/olimorris/codecompanion.nvim',
  'https://github.com/aaholmes/butwhy.nvim',
}
require('codecompanion').setup {}
require('butwhy').setup()
```

Any plugin manager works, as long as `butwhy.setup()` runs after CodeCompanion's setup.

## Tell it who you are

Write a short background file at `~/.config/butwhy/background.md`. It is attached to every
butwhy chat (and only those), so explanations start at your level. Specific topics work better
than job titles:

```markdown
# Reader background

## Strong
- Linear algebra, probability
- Python, NumPy, PyTorch

## Partial
- C++ (can read it; templates are shaky)

## Not familiar
- Compilers, measure-theoretic probability

## Preferences
- Use a concrete numeric or code example whenever possible.
- Define every acronym on first use.
```

Keep it under about 40 lines: it is sent with every request, and small local models start
ignoring parts of long instructions.

## Use

Select text in visual mode and press `<leader>we` (or run `:'<,'>ButwhyExplain`). A pop-up
opens directly under the selection (or above it, near the bottom of the window), the selected
text stays highlighted until the pop-up closes, and the pop-up shows only the answer: a few sentences on what the highlight is and what it does in this
particular file. The prompt and your background are sent to the model but not shown.

The pop-up is an ordinary CodeCompanion chat, so you can type a follow-up question at the bottom
and send it with CodeCompanion's usual keys.

## Choose a model

The default is Mercury 2.5 from Inception Labs, a diffusion language model (it refines many
tokens in parallel rather than generating one at a time), chosen because it is fast and cheap.
Set `INCEPTION_API_KEY` to use it; butwhy defines the `mercury` adapter for you unless you
already have one. That adapter sets Mercury's `reasoning_effort` to `instant`, which skips the
model's hidden reasoning step; at the API's default (`medium`) the first word takes a few seconds
to arrive. You can change it from the chat's settings like any other adapter parameter.

To use something else, pass any CodeCompanion adapter:

```lua
require('butwhy').setup { adapter = { name = 'anthropic', model = 'claude-haiku-4-5-20251001' } }
require('butwhy').setup { adapter = 'ollama' } -- that adapter's default model
require('butwhy').setup { adapter = false }    -- CodeCompanion's configured chat adapter
```

You can also switch adapter inside any open chat with CodeCompanion's own keymap (press `?` in
the chat to list them).

## Options

```lua
require('butwhy').setup {
  background = '~/.config/butwhy/background.md',
  adapter = { name = 'mercury', model = 'mercury-2.5' },
  -- Pop-up window; takes any CodeCompanion chat window option, and affects butwhy chats only.
  -- A floating pop-up is resized to fit its text, wrapping at max_width columns.
  window = { layout = 'float', border = 'rounded', title = ' butwhy ' },
  max_width = 80,
}
```

That highlight uses the `ButwhyHighlight` group, linked by default to `IncSearch`, the group
Neovim flashes when you yank text. Set `ButwhyHighlight` in your colour scheme or with
`vim.api.nvim_set_hl(0, 'ButwhyHighlight', { ... })` to change it.

## Tests

Headless checks. The pop-up checks drive a real chat through a mock model server running
inside Neovim, so no API key or network is needed:

```sh
nvim --headless -u tests/minimal_init.lua -c 'luafile tests/butwhy_spec.lua'
nvim --headless -u tests/minimal_init.lua -c 'luafile tests/popup_spec.lua'
```

Dependencies are loaded with `:packadd`; set `BUTWHY_DEPS` to a directory containing
`plenary.nvim` and `codecompanion.nvim` to use other copies.

## License

MIT; see [LICENSE](LICENSE).
