# butwhy.nvim

Highlight a passage in Neovim, such as a line of code, a paragraph or a LaTeX equation, and get it
explained at your level in a chat beside the file. The highlight is the topic; about 40 lines on
either side are sent as context only, so the answer stays on what you selected.

butwhy is built on [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim), a
Neovim plugin that connects chat buffers to large language model (LLM) providers, so it works
with any model CodeCompanion supports.

**Status:** early. Explaining a highlight, drilling down to simpler levels, and asking your own
questions about a highlight work. Planned next: web search for further reading.

## Requirements

- Neovim 0.12 and CodeCompanion v19 (tested with 0.12.4 and v19.22)
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

Still confused? Press `<leader>ws` in the pop-up (or run `:ButwhySimpler`) to have it re-explained
one level simpler: less jargon, every term the previous answer relied on defined, and a simpler
example. Press it again to keep going; the title shows the level, and the pop-up shows only the
latest answer.

To ask something specific instead, select text and press `<leader>wa` (or run
`:'<,'>ButwhyAsk`). The pop-up opens in Insert mode; type your question and send it with
CodeCompanion's send key (`<C-s>` in Insert mode, `<CR>` in Normal mode, by default). The
highlight and its surroundings are sent along with the question but not shown.

Either pop-up is an ordinary CodeCompanion chat, so you can keep typing follow-up questions at
the bottom.

## Choose a model

The default is Gemma 4 31B on Ollama Cloud, which has a free plan: create a key at ollama.com and
set `OLLAMA_API_KEY`. butwhy defines the `ollama_cloud` adapter for you unless you already have
one. The comparison below explains the choice.

butwhy also defines a `mercury` adapter for Mercury 2.5 from Inception Labs, a diffusion language
model (it refines many tokens in parallel rather than generating one at a time) and the fastest
option tested. Set `INCEPTION_API_KEY` and pass `adapter = 'mercury'` to use it. That adapter sets
Mercury's `reasoning_effort` to `instant`, which skips the model's hidden reasoning step; at the
API's default (`medium`) the first word takes a few seconds to arrive.

To use something else, pass any CodeCompanion adapter:

```lua
require('butwhy').setup { adapter = { name = 'anthropic', model = 'claude-haiku-4-5-20251001' } }
require('butwhy').setup { adapter = 'ollama' } -- that adapter's default model
require('butwhy').setup { adapter = false }    -- CodeCompanion's configured chat adapter
```

You can also switch adapter inside any open chat with CodeCompanion's own keymap (press `?` in
the chat to list them).

### Recommended models

- **Free (the default):** Gemma 4 31B on Ollama Cloud's free plan. It was about as accurate as
  the best models tested, the most consistent at making each "simpler" step genuinely simpler,
  and answered in about a second. Ollama states that cloud prompts are not logged or used for
  training.
- **Most accurate tested:** Kimi K3 or DeepSeek V4 Pro on Baseten, both with reasoning turned off.
  DeepSeek costs less than half as much per token.
- **Fastest and cheapest:** Mercury 2.5 (`adapter = 'mercury'`), at the cost of lower accuracy.

Models on Baseten, Groq and similar hosts use the same OpenAI-compatible format; define an
adapter by extending `openai_compatible` with the host's URL, key variable and model name, as
butwhy's own `ollama_cloud` adapter does in `lua/butwhy/init.lua`.

### Model comparison

Each model explained 13 highlights at four levels (the first answer plus three "simpler"
steps): Python, Rust and C code, a GPU kernel, LaTeX equations, a Markdown design note, and two
Wikipedia passages outside the reader's field (property law and immunology). A separate model
graded every answer using a written reference answer, without knowing which model produced it.
All models ran with reasoning off, or at its lowest setting where it cannot be turned off, so
none was spending extra time thinking. Tested September 2026.

| Model (provider) | Answers fully correct | First answer correct | Steps judged simpler | Median time | Price per 1M tokens (input / output) |
|---|---|---|---|---|---|
| Kimi K3 (Baseten) | 75% (39/52) | 10/13 | 67% | 1.5 s | $3.00 / $15.00 |
| DeepSeek V4 Pro (Baseten) | 67% (35/52) | 7/13 | 72% | 1.2 s | $1.32 / $3.96 |
| Gemma 4 31B (Ollama Cloud) | 62% (32/52) | 9/13 | 85% | 1.0 s | free plan; $0.14 / $0.40 after |
| Mercury 2.5, `instant` (Inception) | 46% (24/52) | 5/13 | 54% | 0.9 s | $0.04 / $0.15 (launch price) |
| Nemotron 3 Ultra (Ollama Cloud) | 44% (23/52) | 3/13 | 74% | 14 s | free plan |
| Qwen 3.8 27B (Groq) | 42% (22/52) | 4/13 | 79% | 0.6 s | free plan |
| Mercury 2.5, `low` (Inception) | 40% (21/52) | 7/13 | 46% | 1.3 s | $0.04 / $0.15 (launch price) |
| gpt-oss-120b, low reasoning (Groq) | 29% (15/52) | 3/13 | 54% | 1.2 s | free plan |

Read the table with its limits in mind. Each model gave one answer per highlight, and 13
highlights is a small set: only gaps of roughly 25 to 30 percentage points are larger than the
noise, so the top three are not distinguishable from each other. The grader was itself a
language model. One highlight, a piece of collision-avoidance geometry, was answered wrongly or
imprecisely by every model. Gemini 3.5 Flash-Lite and Cohere North-mini-code were tested on too
few highlights to include.

## Options

```lua
require('butwhy').setup {
  background = '~/.config/butwhy/background.md',
  adapter = { name = 'ollama_cloud', model = 'gemma4:31b' },
  -- Pop-up window; takes any CodeCompanion chat window option, and affects butwhy chats only.
  -- A floating pop-up is resized to fit its text, wrapping at max_width columns.
  window = { layout = 'float', border = 'rounded', title = ' butwhy ' },
  max_width = 80,
  -- Keys butwhy maps (`simpler` only inside the pop-up); false, for all or one, maps nothing.
  -- :ButwhyExplain, :ButwhyAsk and :ButwhySimpler work either way.
  keymaps = { explain = '<leader>we', ask = '<leader>wa', simpler = '<leader>ws' },
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
nvim --headless -u tests/minimal_init.lua -c 'luafile tests/ask_spec.lua'
```

Dependencies are loaded with `:packadd`; set `BUTWHY_DEPS` to a directory containing
`plenary.nvim` and `codecompanion.nvim` to use other copies.

## License

MIT; see [LICENSE](LICENSE).
