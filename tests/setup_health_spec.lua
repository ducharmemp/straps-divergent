package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

it('rejects non-table setup options before loading core', function()
  local ok, err = pcall(require('straps-divergent').setup, false)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find('setup options must be a table', 1, true))
end)

it('health reports core setup and fork registration', function()
  local saved, health = package.loaded['straps.registry'], vim.health
  local reports = {}
  vim.health = setmetatable({}, { __index = function(_, key) return function(msg) reports[#reports + 1] = key .. ':' .. msg end end })
  package.loaded['straps.registry'] = { get = function() return {} end }
  require('straps-divergent.health').check()
  assert.is_truthy(table.concat(reports):find('ok:Straps setup() has run', 1, true))
  assert.is_truthy(table.concat(reports):find('ok:fork registered', 1, true))
  package.loaded['straps.registry'], vim.health = saved, health
end)
