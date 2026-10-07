local M = {}
local api = vim.api

function M.cwd(win)
  local position = vim.fn.win_id2tabwin(win)
  return vim.fn.getcwd(position[2], position[1])
end

function M.capture()
  local win = api.nvim_get_current_win()
  if vim.bo.buftype == 'prompt' then
    return nil, 'Invoke jj_workspaces from an editing window, not a prompt buffer'
  end
  return {
    win = win,
    tab = api.nvim_win_get_tabpage(win),
    buf = api.nvim_win_get_buf(win),
    cwd = M.cwd(win),
  }
end

function M.valid(origin)
  return api.nvim_win_is_valid(origin.win)
    and api.nvim_tabpage_is_valid(origin.tab)
    and api.nvim_win_get_tabpage(origin.win) == origin.tab
    and api.nvim_win_get_buf(origin.win) == origin.buf
    and M.cwd(origin.win) == origin.cwd
end

function M.call(origin, callback)
  if not M.valid(origin) then
    return false, 'context_changed: originating window, tab, buffer, or cwd changed'
  end
  return pcall(api.nvim_win_call, origin.win, callback)
end

function M.clean(value)
  return tostring(value or ''):gsub('[%z\1-\31\127]', function(character)
    return string.format('\\x%02x', character:byte())
  end)
end

function M.notify(message, level)
  vim.notify('jj_workspaces: ' .. M.clean(message):sub(1, 4096), level or vim.log.levels.WARN)
end

return M
