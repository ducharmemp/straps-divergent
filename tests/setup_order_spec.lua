-- tests/setup_order_spec.lua — straps-divergent refuses to register before
-- straps itself is set up (its prompt layer must land after the core layers).
-- Run from the repo root:
--   busted tests/setup_order_spec.lua
-- Its own process: the order of setup() calls is per-process state.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
local straps_dir = vim.env.STRAPS_DIR or vim.fn.fnamemodify(root, ":h") .. "/straps"
assert(vim.fn.isdirectory(straps_dir .. "/lua/straps") == 1,
  "straps checkout not found at " .. straps_dir .. " (set STRAPS_DIR)")
vim.opt.runtimepath:prepend(straps_dir)
vim.opt.runtimepath:prepend(root)
package.path = straps_dir .. "/lua/?.lua;" .. straps_dir .. "/lua/?/init.lua;"
  .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry = require("straps.registry")

it("setup before straps.setup() errors and defines nothing", function()
  local ok, err = pcall(require("straps-divergent").setup)
  assert(not ok, "setup should fail before straps is set up")
  assert(tostring(err):find('call require("straps").setup() before', 1, true), tostring(err))
  assert(registry.get("tool.fork") == nil, "nothing should be registered on failure")
  assert(vim.fn.exists(":StrapsFork") == 0, "no command on failure")
end)

it("setup after straps.setup() registers, and a second setup keeps redefinitions", function()
  require("straps").setup({})
  require("straps").config.session_dir = vim.fn.tempname()
  require("straps-divergent").setup()
  assert(registry.get("tool.fork"), "tool.fork registered")
  registry.define({ name = "fn.fork_section", kind = "fn", doc = "user", source = "return function() return 'mine' end" },
    { scope = "global" })
  require("straps-divergent").setup()
  assert(registry.call("fn.fork_section") == "mine", "define_default must not clobber a redefinition")
end)
