-- Tiny test harness shared by the specs: check(name, fn), eq(got, want, what), finish().
local H = { failures = 0, passes = 0 }

function H.check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passes = H.passes + 1
    io.write('ok    ', name, '\n')
  else
    H.failures = H.failures + 1
    io.write('FAIL  ', name, '\n      ', tostring(err), '\n')
  end
end

function H.eq(got, want, what)
  if got ~= want then error(string.format('%s: got %s, want %s', what or 'value', vim.inspect(got), vim.inspect(want)), 2) end
end

function H.finish()
  io.write(string.format('\n%d passed, %d failed\n', H.passes, H.failures))
  vim.cmd(H.failures == 0 and 'qa!' or 'cq!')
end

return H
