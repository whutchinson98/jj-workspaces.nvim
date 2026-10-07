-- Neovim capability checks, not tests of an implemented plugin.
-- Run: nvim --headless --clean -l tests/probes/editor.lua
local original = vim.fn.getcwd()
local base = vim.fn.tempname()
local paths = {
  global = base .. "/global",
  tab = base .. "/tab",
  window = base .. "/window with spaces | and 'quotes'",
  other_tab = base .. "/other tab",
}
local checks = 0
local function equal(actual, expected)
  assert(actual == expected, vim.inspect({ actual = actual, expected = expected }))
  checks = checks + 1
end
local function cwd(win)
  local position = vim.fn.win_id2tabwin(win)
  return vim.fn.getcwd(position[2], position[1])
end
local ok, err = xpcall(function()
  for _, path in pairs(paths) do
    vim.fn.mkdir(path, "p")
  end
  assert(type(vim.system) == "function" and type(vim.json.decode) == "function")
  vim.api.nvim_cmd({ cmd = "cd", args = { paths.global }, magic = { file = false } }, {})
  local first = vim.api.nvim_get_current_win()
  equal(cwd(first), paths.global)
  vim.cmd("tabnew")
  local second = vim.api.nvim_get_current_win()
  equal(cwd(second), paths.global)
  vim.api.nvim_cmd({ cmd = "tcd", args = { paths.tab }, magic = { file = false } }, {})
  equal(cwd(first), paths.global)
  equal(cwd(second), paths.tab)
  vim.cmd("vsplit")
  local third = vim.api.nvim_get_current_win()
  vim.api.nvim_cmd({ cmd = "lcd", args = { paths.window }, magic = { file = false } }, {})
  equal(cwd(first), paths.global)
  equal(cwd(second), paths.tab)
  equal(cwd(third), paths.window)
  -- Structured arguments handle spaces and an Ex command separator literally.
  equal(vim.fn.isdirectory(paths.window), 1)
  vim.api.nvim_win_call(first, function()
    vim.api.nvim_cmd({ cmd = "tcd", args = { paths.other_tab }, magic = { file = false } }, {})
  end)
  equal(cwd(first), paths.other_tab)
  equal(cwd(second), paths.tab)
  equal(cwd(third), paths.window)
  equal(vim.api.nvim_get_current_win(), third)
  local function jump_count(win)
    local position = vim.fn.win_id2tabwin(win)
    return #vim.fn.getjumplist(position[2], position[1])[1]
  end
  for _, win in ipairs({ first, third }) do
    vim.api.nvim_win_call(win, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
      })
      vim.cmd("normal! gg")
      vim.cmd("normal! 5G")
      vim.cmd("normal! 10G")
    end)
    assert(jump_count(win) > 0, "Expected a populated jumplist")
  end
  local other_jumps = jump_count(third)
  vim.api.nvim_win_call(first, function() vim.cmd("clearjumps") end)
  equal(jump_count(first), 0)
  equal(jump_count(third), other_jumps)
  equal(vim.api.nvim_get_current_win(), third)
end, debug.traceback)
-- Close temporary windows and leave the fixture before removing it.
vim.cmd("silent! tabonly!")
vim.cmd("silent! only!")
vim.api.nvim_cmd({ cmd = "cd", args = { original }, magic = { file = false } }, {})
vim.fn.delete(base, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(string.format("Neovim capability probe: %d checks passed (%s)", checks, vim.inspect(vim.version())))
vim.cmd("qa!")
