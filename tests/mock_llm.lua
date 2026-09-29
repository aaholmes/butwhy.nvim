-- A fake OpenAI-compatible chat endpoint running inside Neovim's event loop, so tests can
-- drive a real CodeCompanion chat end to end without a network or an API key.
-- start(chunks) returns { port, requests }: each POST's decoded JSON body is appended to
-- `requests` and answered by streaming `chunks` as the assistant's reply (or chunks[n] for the
-- nth request, if chunks is a list of lists); GET (the model list)
-- returns one model, `mock-model`.
local M = {}

local function sse(chunks)
  local out = { 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n' }
  for i, text in ipairs(chunks) do
    local delta = i == 1 and { role = 'assistant', content = text } or { content = text }
    table.insert(out, 'data: ' .. vim.json.encode { id = 'mock', object = 'chat.completion.chunk', choices = { { index = 0, delta = delta } } } .. '\n\n')
  end
  table.insert(out, 'data: ' .. vim.json.encode { id = 'mock', choices = { { index = 0, delta = vim.empty_dict(), finish_reason = 'stop' } } } .. '\n\n')
  table.insert(out, 'data: [DONE]\n\n')
  return table.concat(out)
end

function M.start(chunks)
  local state = { requests = {} }
  local server = assert(vim.uv.new_tcp())
  server:bind('127.0.0.1', 0)
  server:listen(16, function()
    local client = assert(vim.uv.new_tcp())
    server:accept(client)
    local buf, continued = '', false
    client:read_start(function(err, data)
      if err or not data then return client:close() end
      buf = buf .. data
      local head_end = buf:find('\r\n\r\n', 1, true)
      if not head_end then return end
      local head = buf:sub(1, head_end)
      if not continued and head:lower():find('expect: 100%-continue') then
        continued = true
        client:write 'HTTP/1.1 100 Continue\r\n\r\n'
      end
      local len = tonumber(head:lower():match 'content%-length:%s*(%d+)') or 0
      local body = buf:sub(head_end + 4)
      if #body < len then return end
      client:read_stop()
      if head:match '^GET' then
        local json = vim.json.encode { object = 'list', data = { { id = 'mock-model', object = 'model' } } }
        local reply = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' .. #json .. '\r\nConnection: close\r\n\r\n' .. json
        return client:write(reply, function() client:close() end)
      end
      state.count = (state.count or 0) + 1
      local reply = type(chunks[1]) == 'table' and (chunks[state.count] or chunks[#chunks]) or chunks
      vim.schedule(function() table.insert(state.requests, vim.json.decode(body)) end)
      client:write(sse(reply), function() client:close() end)
    end)
  end)
  state.port = server:getsockname().port
  return state
end

return M
