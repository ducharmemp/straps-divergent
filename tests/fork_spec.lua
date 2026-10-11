-- tests/fork_spec.lua — straps-divergent: fn.fork, fn.fork_section, tool.fork,
-- fn.system_prompt_layer.divergent and :StrapsFork. Run from the repo root:
--   busted tests/fork_spec.lua
-- straps is located via $STRAPS_DIR, else ../straps next to this checkout.
-- No network: fn.provider is scripted per case.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
local straps_dir = vim.env.STRAPS_DIR or vim.fn.fnamemodify(root, ":h") .. "/straps"
assert(vim.fn.isdirectory(straps_dir .. "/lua/straps") == 1,
  "straps checkout not found at " .. straps_dir .. " (set STRAPS_DIR)")
vim.opt.runtimepath:prepend(straps_dir)
vim.opt.runtimepath:prepend(root)
package.path = straps_dir .. "/lua/?.lua;" .. straps_dir .. "/lua/?/init.lua;"
  .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.stop_backstop_ms = 400
require("straps-divergent").setup()

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

local function define(name, kind, doc, source)
  registry.define({ name = name, kind = kind, doc = doc, source = source }, { scope = "global" })
end

local function allow_all()
  define("hook.confirm", "hook", "test: allow everything", "return function() return true end")
end
allow_all()

local function text_of(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function wait_idle(bufnr, ms)
  assert(vim.wait(ms or 10000, function() return not loop.running(bufnr) end, 10),
    "run did not finish in time")
end

local function provider(src)
  define("fn.provider", "fn", "test provider", src)
end

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function drive(thunk, timeout_ms)
  local out, finished, co
  local ctx
  ctx = {
    bufnr = 0,
    await = function(start)
      local resolved = false
      start(function(...)
        if resolved then return end
        resolved = true
        local a = pack(...)
        vim.schedule(function()
          if coroutine.status(co) == "suspended" then
            local ok, e = coroutine.resume(co, unpack(a, 1, a.n))
            if not ok then finished = true; error(e) end
          end
        end)
      end)
      return coroutine.yield()
    end,
  }
  co = coroutine.create(function()
    out = thunk(ctx)
    finished = true
  end)
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
  vim.wait(timeout_ms or 20000, function() return finished end, 20)
  assert(finished, "drive: thunk did not finish within timeout")
  return out
end

-- A source transcript shaped like a session caught mid-turn, exactly as the
-- loop leaves it while the fork tool runs: every tool_use marker of the batch
-- is already appended, the calls before the fork have results, the fork call
-- and the calls after it do not.
local function mid_turn_source()
  local s = state.new_session()
  vim.api.nvim_buf_set_lines(s, 0, -1, false, {})
  state.append(s, "system", nil, "SYSTEM-PROMPT-TEXT")
  state.append(s, "user", nil, "first request")
  state.append(s, "assistant", nil, "reading")
  state.append(s, "tool_use", { id = "t_a", name = "read_file" }, '{"path": "a.lua"}')
  state.append(s, "tool_result", { id = "t_a", is_error = false }, "contents of a.lua")
  state.append(s, "assistant", nil, "forking now")
  state.append(s, "tool_use", { id = "t_fork", name = "fork" }, '{"task": "do X"}')
  state.append(s, "tool_use", { id = "t_b", name = "grep" }, '{"pattern": "zzz"}')
  return s
end

local function user_texts(parsed)
  local out = {}
  for _, m in ipairs(parsed.messages) do
    if m.role == "user" then
      for _, p in ipairs(m.content) do
        if p.type == "text" then out[#out + 1] = p.text end
      end
    end
  end
  return out
end

local function result_of(parsed, id)
  for _, m in ipairs(parsed.messages) do
    for _, p in ipairs(m.content) do
      if p.type == "tool_result" and p.tool_use_id == id then return p end
    end
  end
  return nil
end

-- --------------------------------------------------------------- registration

it("setup registers the entries and the command", function()
  for _, name in ipairs({ "fn.fork", "fn.fork_section", "tool.fork", "fn.system_prompt_layer.divergent" }) do
    assert(registry.get(name), name .. " should be registered")
  end
  assert(registry.get("tool.fork").capability == "spawn", "tool.fork should carry capability = spawn")
  assert(registry.call("fn.capability", "fork") == "spawn", "fn.capability should classify fork as spawn")
  assert(vim.fn.exists(":StrapsFork") == 2, ":StrapsFork should exist")
  local prompt = registry.call("fn.system_prompt", {})
  assert(prompt:find("\n# Forking\n", 1, true), "the system prompt should carry the # Forking section")
  local core_at = prompt:find("# Subagents", 1, true)
  local fork_at = prompt:find("# Forking", 1, true)
  assert(core_at and fork_at and fork_at > core_at, "# Forking must land after the core layers")
end)

it("the fork tool is listed by fn.build_tools", function()
  local found = false
  for _, t in ipairs(registry.call("fn.build_tools")) do
    if t.name == "fork" then found = true end
  end
  assert(found, "fork missing from the tool list")
end)

-- ---------------------------------------------------------------------- copy

it("fn.fork copies the transcript, pairs the open tool calls and appends the task", function()
  local s = mid_turn_source()
  local src_lines = vim.api.nvim_buf_get_lines(s, 0, -1, false)
  local child = registry.call("fn.fork", s, { relation = "child", task = "the fork task", start = false })
  assert(child ~= s and vim.api.nvim_buf_is_valid(child), "fork should be a new valid buffer")
  assert(vim.b[child].straps_session == true, "fork should be a session buffer")

  local blocks = state.list_blocks(child)
  assert(blocks[1].kind == "system", "fork should start with the system block")
  local sys_text = table.concat(
    vim.api.nvim_buf_get_lines(child, blocks[1].first_lnum - 1, blocks[1].last_lnum, false), "\n")
  assert(sys_text:find("^SYSTEM%-PROMPT%-TEXT"), "the source prompt must be kept verbatim at the top")
  assert(sys_text:find("# You are a fork", 1, true), "the fork section must be appended to the system block")
  assert(sys_text:find(("fork of session buffer %d, cut after block 8"):format(s), 1, true),
    "the section must name the source buffer and the cut block:\n" .. sys_text)

  -- Everything after the system block is byte-identical to the source.
  local src_blocks = state.list_blocks(s)
  local src_after = table.concat(vim.list_slice(src_lines, src_blocks[2].marker_lnum), "\n")
  local n_src = #src_lines - src_blocks[2].marker_lnum + 1
  local child_after = table.concat(
    vim.api.nvim_buf_get_lines(child, blocks[2].marker_lnum - 1, blocks[2].marker_lnum - 1 + n_src, false), "\n")
  assert(child_after == src_after, "copied message blocks must match the source byte for byte")

  local parsed = state.parse(child)
  assert(parsed.system:find("# You are a fork", 1, true), "parse must see the section as system text")
  local ra = result_of(parsed, "t_a")
  assert(ra and ra.is_error == false and ra.content == "contents of a.lua", "t_a keeps its real result")
  local rf = result_of(parsed, "t_fork")
  assert(rf and rf.is_error == false and rf.content:find("this transcript is the fork", 1, true),
    "the fork call gets a success result in the fork")
  local rb = result_of(parsed, "t_b")
  assert(rb and rb.is_error == true and rb.content:find("not run in this fork", 1, true),
    "a later sibling call gets an error result")
  local last = parsed.messages[#parsed.messages]
  assert(last.role == "user", "the transcript must end on a user message")
  assert(last.content[1].type == "tool_result", "tool results come first in the final user message")
  assert(last.content[#last.content].type == "text" and last.content[#last.content].text == "the fork task",
    "the task is the last part of the final user message")
  local n_results = 0
  for _, p in ipairs(last.content) do if p.type == "tool_result" then n_results = n_results + 1 end end
  assert(n_results == 2, "exactly two synthetic results, got " .. n_results)
  assert(text_of(s) == table.concat(src_lines, "\n"), "the source transcript must be untouched")
end)

it("only the first unpaired fork call is claimed when a batch holds two", function()
  local s = mid_turn_source()
  state.append(s, "tool_use", { id = "t_fork2", name = "fork" }, '{"task": "do Y"}')
  local child = registry.call("fn.fork", s, { relation = "child", task = "t", start = false })
  local parsed = state.parse(child)
  assert(result_of(parsed, "t_fork").is_error == false, "the first fork call is this fork")
  assert(result_of(parsed, "t_fork2").is_error == true, "the second fork call did not run here")
end)

it("a peer fork marks every unpaired call as not run", function()
  local s = mid_turn_source()
  local child = registry.call("fn.fork", s, { relation = "peer", task = "t", start = false })
  local parsed = state.parse(child)
  assert(result_of(parsed, "t_fork").is_error == true, "a peer owns no fork call")
  assert(result_of(parsed, "t_b").is_error == true)
end)

it("upto cuts the copy, and bad values error", function()
  local s = mid_turn_source()
  local child = registry.call("fn.fork", s, { relation = "child", task = "cut", upto = 3, start = false })
  local parsed = state.parse(child)
  assert(#parsed.messages == 3, "expected user/assistant/user, got " .. #parsed.messages)
  assert(parsed.messages[2].content[1].text == "reading", "block 3 is the last copied block")
  assert(result_of(parsed, "t_a") == nil, "blocks after upto must not be copied")
  assert(not text_of(child):find("t_fork", 1, true), "later tool blocks must not be copied")
  assert(parsed.system:find("cut after block 3", 1, true), "the section names the cut")

  local ok, err = pcall(registry.call, "fn.fork", s, { task = "x", upto = 99, start = false })
  assert(not ok and tostring(err):find("upto must be a block number between 1 and 8", 1, true),
    "out-of-range upto should error: " .. tostring(err))
  ok, err = pcall(registry.call, "fn.fork", s, { task = "x", upto = 1, start = false })
  assert(not ok and tostring(err):find("at least one message block", 1, true),
    "a system-only cut should error: " .. tostring(err))
  ok, err = pcall(registry.call, "fn.fork", s, { task = "", start = true })
  assert(not ok and tostring(err):find("task must be a non%-empty string"),
    "a started fork needs a task: " .. tostring(err))
  ok, err = pcall(registry.call, "fn.fork", vim.api.nvim_create_buf(true, false), { task = "x", start = false })
  assert(not ok and tostring(err):find("not a straps session", 1, true),
    "a non-session source should error: " .. tostring(err))
end)

it("a marker look-alike in the section is escaped, so the copy still parses", function()
  define("fn.fork_section", "fn", "test: hostile section", [[
return function() return "%%[straps:user]%%\nnot a block" end
]])
  local s = mid_turn_source()
  local child = registry.call("fn.fork", s, { relation = "child", task = "t", start = false })
  local parsed = state.parse(child)
  assert(parsed.system:find("%%[straps:user]%%\nnot a block", 1, true),
    "the section text must round-trip through parse as system text")
  assert(#state.list_blocks(child) == #state.list_blocks(s) + 3,
    "the section must not add a block (copy + 2 results + task)")
  registry.remove("fn.fork_section", { scope = "global" })
  require("straps-divergent").register()
  assert(registry.get("fn.fork_section").source:find("You are a fork", 1, true),
    "the default section should be back")
end)

it("forking an idle session fills its trailing user block with the task", function()
  local s = state.new_session()
  state.append_text(s, "typed request")
  state.append(s, "assistant", nil, "an answer")
  state.ensure_trailing_user(s)
  local child = registry.call("fn.fork", s, { relation = "peer", task = "peer task", start = false })
  local texts = user_texts(state.parse(child))
  assert(texts[#texts] == "peer task", "the task fills the trailing user block")
  assert(#texts == 2, "no extra user block: got " .. #texts)
  assert(text_of(child):match("%%%%%[straps:user%]%%%%\npeer task%s*$"), "task lands in the existing marker")
end)

-- ---------------------------------------------------------------- shaping

it("a child fork is shaped like a spawn child; a peer is independent", function()
  local s = state.new_session()
  state.append_text(s, "go")
  vim.b[s].straps_spawn_depth = 0
  vim.b[s].straps_model = "model-of-source"
  vim.b[s].straps_effort = "low"
  vim.b[s].straps_tool_filter = { "read_file", "fork" }
  registry.grant(s, "cap:exec")
  registry.grant(s, "spawn:gated")

  local c = registry.call("fn.fork", s, { relation = "child", task = "  child   task  ", start = false,
    max_turns = 3, timeout_ms = 1234 })
  assert(vim.b[c].straps_parent == s, "child fork records its parent")
  assert(vim.b[c].straps_spawn_depth == 1, "child fork is one level deeper")
  assert(vim.b[c].straps_task == "child task", "task is collapsed for the agents picker")
  assert(vim.b[c].straps_max_turns == 3)
  assert(vim.b[c].straps_spawn_timeout_ms == 1234)
  assert(type(vim.b[c].straps_spawn_started_ms) == "number")
  assert(vim.b[c].straps_model == "model-of-source", "model inherited")
  assert(vim.b[c].straps_effort == "low", "effort inherited")
  assert(vim.deep_equal(vim.b[c].straps_tool_filter, { "read_file", "fork" }), "tool filter copied")
  local g = registry.granted(c)
  assert(g["cap:exec"] == true and g["spawn:gated"] == true, "grants copied")
  assert(registry.scope_parent(c) == s, "scope chained under the source")
  local sys = state.parse(c).system
  assert(sys:find("The source session is your parent", 1, true), "child section text")
  assert(not sys:find("forked this session by hand", 1, true), "no peer text in a child")

  local p = registry.call("fn.fork", s, { relation = "peer", task = "peer", start = false,
    model = "override-model", effort = "high" })
  assert(vim.b[p].straps_parent == nil, "a peer has no parent")
  assert(vim.b[p].straps_task == nil, "a peer carries no task label")
  assert(vim.b[p].straps_spawn_depth == 0, "a peer keeps the source depth")
  assert(vim.b[p].straps_model == "override-model", "explicit model wins")
  assert(vim.b[p].straps_effort == "high", "explicit effort wins")
  assert(registry.granted(p)["cap:exec"] == true, "a peer still carries the grants")
  local psys = state.parse(p).system
  assert(psys:find("forked this session by hand", 1, true), "peer section text")
  assert(not psys:find("The source session is your parent", 1, true), "no child text in a peer")
end)

it("the section says spawn and fork are unavailable only at the depth limit", function()
  local saved = straps.config.max_spawn_depth
  straps.config.max_spawn_depth = 2
  local s = state.new_session()
  state.append_text(s, "go")
  vim.b[s].straps_spawn_depth = 0
  local c1 = registry.call("fn.fork", s, { relation = "child", task = "t", start = false })
  assert(not state.parse(c1).system:find("spawn and fork are unavailable", 1, true),
    "depth 1 of 2 still has budget")
  local c2 = registry.call("fn.fork", c1, { relation = "child", task = "t", start = false })
  assert(state.parse(c2).system:find("spawn and fork are unavailable", 1, true),
    "depth 2 of 2 is the limit")
  straps.config.max_spawn_depth = saved
end)

it("a session-scoped tool of the source is callable from the fork", function()
  local s = state.new_session()
  state.append_text(s, "go")
  registry.define({ name = "tool.probe", kind = "tool", doc = "d",
    source = "return function() return 'probed' end" }, { scope = s })
  local c = registry.call("fn.fork", s, { relation = "child", task = "t", start = false })
  local prev = registry.set_active_scope(c)
  local ok, out = pcall(registry.call, "tool.probe", {}, { bufnr = c })
  registry.set_active_scope(prev)
  assert(ok and out == "probed", "scoped tool should resolve through the chain: " .. tostring(out))
end)

it("a gated source's confirm reaches the fork: writes are denied without a prompt", function()
  local parent = state.new_session()
  state.append_text(parent, "go")
  local gated
  drive(function(ctx)
    ctx.bufnr = parent
    local started = registry.call("tool.spawn", { task = "GATED", readonly = true, allow = nil }, ctx)
    gated = tonumber(started:match("buffer (%d+)"))
    pcall(loop.stop, gated)
    return started
  end)
  wait_idle(gated)
  assert(registry.granted(gated)["spawn:gated"] == true, "spawn should have gated its child")

  local fork = registry.call("fn.fork", gated, { relation = "child", task = "t", start = false })
  local prev = registry.set_active_scope(fork)
  local allowed, reason = registry.call("hook.confirm", "write_file", { path = "/tmp/x", content = "" }, { bufnr = fork })
  registry.set_active_scope(prev)
  assert(allowed == false, "the fork must inherit the gated confirm")
  assert(tostring(reason):find("readonly subagent", 1, true), "denied by the readonly gate: " .. tostring(reason))
end)

-- ---------------------------------------------------------------- the tool

local FORK_AWARE_PROVIDER = [==[
return function(req, ctx)
  local is_fork = type(req.system) == "string" and req.system:find("# You are a fork", 1, true)
  ctx.await(function(resolve) vim.defer_fn(resolve, 20) end)
  if is_fork then
    ctx.emit({ type = "text_delta", text = "FORK-DONE" })
    ctx.await(function(resolve) vim.defer_fn(resolve, 10) end)
    return { stop_reason = "end_turn", content = { { type = "text", text = "FORK-DONE" } } }
  end
  ctx.emit({ type = "text_delta", text = "SOURCE-DONE" })
  ctx.await(function(resolve) vim.defer_fn(resolve, 10) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "SOURCE-DONE" } } }
end
]==]

it("tool.fork starts a child that spawn_wait collects", function()
  provider(FORK_AWARE_PROVIDER)
  local parent = state.new_session()
  state.append_text(parent, "please fork")
  state.append(parent, "assistant", nil, "")
  state.append(parent, "tool_use", { id = "t_f", name = "fork" }, '{"task": "finish it"}')
  registry.grant(parent, "cap:exec")
  local child
  local out = drive(function(ctx)
    ctx.bufnr = parent
    local started = registry.call("tool.fork", { task = "finish it", show = true }, ctx)
    assert(started:find("fork started", 1, true), started)
    child = tonumber(started:match("buffer (%d+)"))
    assert(started:find(("spawn_wait{ buffers = { %d } }"):format(child), 1, true), started)
    return registry.call("tool.spawn_wait", { buffers = { child } }, ctx)
  end)
  assert(out:find("FORK-DONE", 1, true), "spawn_wait should return the fork's reply:\n" .. out)
  assert(out:find("task: finish it", 1, true), "spawn_wait should show the task:\n" .. out)
  assert(out:find("finished", 1, true), out)
  assert(registry.granted(child)["cap:exec"] == true, "grants copied from inside the tool body")
  local rf = result_of(state.parse(child), "t_f")
  assert(rf and rf.is_error == false, "the executing fork call is claimed in the child")
  assert(vim.api.nvim_win_get_buf(0) ~= child, "show=true must not steal focus from the parent")
  local shown = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == child then shown = true; vim.api.nvim_win_close(w, true) end
  end
  assert(shown, "show=true should open the fork in a window")
end)

it("an upto cut never claims a fork call, and a mid-transcript orphan is left alone", function()
  local s = mid_turn_source()
  state.append(s, "tool_result", { id = "t_fork", is_error = false }, "earlier fork result")
  state.append(s, "assistant", nil, "later turn")
  state.append(s, "tool_use", { id = "t_c", name = "fork" }, '{"task": "again"}')
  -- Cut between the earlier fork call and its result: that call belongs to an
  -- earlier run, so this fork must not claim it.
  local child = registry.call("fn.fork", s, { relation = "child", task = "t", upto = 7, start = false })
  local parsed = state.parse(child)
  assert(result_of(parsed, "t_fork").is_error == true, "a cut-off fork call is not this fork")
  -- Whole copy: t_b is an orphan with conversation after it, so the copy is
  -- not an interrupted tail and nothing is paired (the source itself is
  -- unsendable in this shape; the fork copies it unchanged).
  child = registry.call("fn.fork", s, { relation = "child", task = "t", start = false })
  parsed = state.parse(child)
  assert(result_of(parsed, "t_b") == nil, "a mid-transcript orphan gets no synthetic result")
  assert(result_of(parsed, "t_c") == nil, "nothing after a mid-transcript orphan is paired either")
  local n_results = 0
  for _, b in ipairs(state.list_blocks(child)) do
    if b.kind == "tool_result" then n_results = n_results + 1 end
  end
  assert(n_results == 2, "only the source's own two results, got " .. n_results)
  -- A clean later turn: only the trailing run is paired, and t_c is this fork.
  state.append(s, "tool_result", { id = "t_c", is_error = true }, "x")
  state.append(s, "tool_result", { id = "t_b", is_error = false }, "late result for b")
  state.append(s, "assistant", nil, "last turn")
  state.append(s, "tool_use", { id = "t_d", name = "fork" }, '{"task": "final"}')
  child = registry.call("fn.fork", s, { relation = "child", task = "t", start = false })
  parsed = state.parse(child)
  assert(result_of(parsed, "t_d").is_error == false, "the trailing fork call is this fork")
  -- A peer never claims; an explicit upto at the end still does; a cut that
  -- keeps the fork call but drops a later sibling of the same batch does too.
  child = registry.call("fn.fork", s, { relation = "peer", task = "t", start = false })
  assert(result_of(state.parse(child), "t_d").is_error == true, "a peer owns no fork call")
  local n = #state.list_blocks(s)
  child = registry.call("fn.fork", s, { relation = "child", task = "t", upto = n, start = false })
  assert(result_of(state.parse(child), "t_d").is_error == false, "explicit upto at the end claims")
  state.append(s, "tool_use", { id = "t_e", name = "grep" }, '{}')
  child = registry.call("fn.fork", s, { relation = "child", task = "t", upto = n, start = false })
  parsed = state.parse(child)
  assert(result_of(parsed, "t_d").is_error == false, "a cut inside the trailing batch still claims")
  assert(result_of(parsed, "t_e") == nil, "the sibling past the cut is not copied")
end)

it("a source whose user marker carries inline text gets the task as a second user block", function()
  local s = state.new_session()
  state.append_text(s, "go")
  state.append(s, "assistant", nil, "a")
  state.ensure_trailing_user(s)
  local last = vim.api.nvim_buf_line_count(s)
  vim.api.nvim_buf_set_lines(s, last - 1, last, false, { "%%[straps:user]%% inline draft" })
  local child = registry.call("fn.fork", s, { relation = "peer", task = "the task", start = false })
  local texts = user_texts(state.parse(child))
  assert(texts[#texts - 1] == "inline draft" and texts[#texts] == "the task", vim.inspect(texts))
end)

it("tool.fork refuses at the depth limit without creating a buffer", function()
  local saved = straps.config.max_spawn_depth
  straps.config.max_spawn_depth = 1
  local parent = state.new_session()
  vim.b[parent].straps_spawn_depth = 1
  local before = #vim.api.nvim_list_bufs()
  local out = drive(function(ctx)
    ctx.bufnr = parent
    return registry.call("tool.fork", { task = "x" }, ctx)
  end)
  assert(out:find("fork: refused", 1, true), out)
  assert(#vim.api.nvim_list_bufs() == before, "no buffer should be created on refusal")
  local ok, err = pcall(drive, function(ctx)
    ctx.bufnr = parent
    return registry.call("tool.fork", { task = "" }, ctx)
  end)
  assert(not ok and tostring(err):find("task must be a non%-empty string"), tostring(err))
  straps.config.max_spawn_depth = saved
end)

it("stopping the source stops a child fork and leaves a peer fork running", function()
  provider([==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 6000) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "late" } } }
end
]==])
  local parent = state.new_session()
  state.append_text(parent, "go")
  vim.b[parent].straps_max_turns = 7
  local child = registry.call("fn.fork", parent, { relation = "child", task = "c" })
  local peer = registry.call("fn.fork", parent, { relation = "peer", task = "p" })
  assert(vim.b[peer].straps_max_turns == 7, "a peer inherits the source's turn cap")
  assert(vim.b[child].straps_max_turns == 24, "a child gets the subagent default cap")
  loop.start(parent)
  vim.wait(50)
  assert(loop.running(child) and loop.running(peer) and loop.running(parent), "all three should be running")
  loop.stop(parent)
  wait_idle(child, 1000)
  assert(loop.running(peer), "a peer fork must outlive the source's stop")
  loop.stop(peer)
  wait_idle(peer, 1000)
  wait_idle(parent, 1000)
end)

-- -------------------------------------------------------------- :StrapsFork

local function fork_bufs_since(before)
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before[b] and vim.b[b].straps_session == true then out[#out + 1] = b end
  end
  return out
end

local function snapshot_bufs()
  local seen = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do seen[b] = true end
  return seen
end

it(":StrapsFork forks the current idle session into a running peer in a split", function()
  provider(FORK_AWARE_PROVIDER)
  local s = state.new_session()
  state.append_text(s, "original request")
  state.append(s, "assistant", nil, "original answer")
  state.ensure_trailing_user(s)
  vim.api.nvim_set_current_buf(s)
  local src_text = text_of(s)
  local before = snapshot_bufs()
  local wins_before = #vim.api.nvim_list_wins()

  vim.cmd("StrapsFork -- try the other approach")
  local forks = fork_bufs_since(before)
  assert(#forks == 1, "one fork expected, got " .. #forks)
  local f = forks[1]
  assert(#vim.api.nvim_list_wins() == wins_before + 1, "the fork opens in a new window")
  assert(vim.api.nvim_win_get_buf(0) == f, "the fork window is focused")
  assert(vim.b[f].straps_parent == nil, "a command fork is a peer")
  wait_idle(f)
  local t = text_of(f)
  assert(t:find("try the other approach", 1, true), "instruction appended")
  assert(t:find("FORK-DONE", 1, true), "the peer ran to completion:\n" .. t:sub(-300))
  assert(t:find("forked this session by hand", 1, true), "peer section text")
  assert(text_of(s) == src_text, "the source must be untouched")
  vim.cmd("close")
end)

it(":StrapsFork! leaves the fork idle, honors upto and :vertical", function()
  local s = state.new_session()
  state.append_text(s, "first")
  state.append(s, "assistant", nil, "one")
  state.append(s, "user", nil, "SECOND-REQUEST")
  state.append(s, "assistant", nil, "two")
  state.ensure_trailing_user(s)
  vim.cmd("only")
  vim.api.nvim_set_current_buf(s)
  local src_win = vim.api.nvim_get_current_win()
  local before = snapshot_bufs()
  vim.cmd("vertical StrapsFork! 3 -- edit me first")
  local f = fork_bufs_since(before)[1]
  assert(f, "fork buffer expected")
  assert(not loop.running(f), "! must not start the run")
  assert(vim.api.nvim_win_get_buf(0) == f, "the fork window is focused")
  local pos_src = vim.api.nvim_win_get_position(src_win)
  local pos_fork = vim.api.nvim_win_get_position(0)
  assert(pos_src[1] == pos_fork[1] and pos_src[2] ~= pos_fork[2], ":vertical should open a vsplit")
  local parsed = state.parse(f)
  local texts = user_texts(parsed)
  assert(#texts == 2 and texts[2] == "edit me first", "upto 3 keeps one exchange; got " .. vim.inspect(texts))
  assert(not text_of(f):find("SECOND-REQUEST", 1, true), "blocks past upto are dropped")
  assert(text_of(f):match("%%%%%[straps:user%]%%%%\nedit me first%s*$"), "instruction in the trailing user block")
  vim.cmd("close")

  before = snapshot_bufs()
  vim.cmd("StrapsFork!")
  f = fork_bufs_since(before)[1]
  assert(f and not loop.running(f), "a bare ! fork is idle")
  assert(text_of(f):match("%%%%%[straps:user%]%%%%%s*$"), "a bare ! fork ends on an empty user block")
  local pos_fork2 = vim.api.nvim_win_get_position(0)
  local pos_src2 = vim.api.nvim_win_get_position(src_win)
  assert(pos_fork2[2] == pos_src2[2] and pos_fork2[1] ~= pos_src2[1], "a plain :StrapsFork opens a horizontal split")
  vim.cmd("close")

  local tabs_before = #vim.api.nvim_list_tabpages()
  before = snapshot_bufs()
  vim.cmd("tab StrapsFork! -- in a tab")
  f = fork_bufs_since(before)[1]
  assert(f and #vim.api.nvim_list_tabpages() == tabs_before + 1, ":tab StrapsFork opens a new tabpage")
  assert(vim.api.nvim_win_get_buf(0) == f, "the tab shows the fork")
  vim.cmd("tabclose")
  vim.api.nvim_set_current_win(src_win)

  -- A source whose trailing user block holds an unsent draft keeps the draft
  -- and gets the instruction as a second user block.
  state.append_text(s, "unsent draft")
  before = snapshot_bufs()
  vim.cmd("StrapsFork! -- after the draft")
  f = fork_bufs_since(before)[1]
  texts = user_texts(state.parse(f))
  assert(texts[#texts - 1] == "unsent draft" and texts[#texts] == "after the draft",
    "draft kept, instruction appended: " .. vim.inspect(texts))
  vim.cmd("close")
end)

it(":StrapsFork refuses on a running session, a non-session buffer and bad args", function()
  local real_notify = vim.notify
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
  local ok, err = pcall(function()
    local before = snapshot_bufs()
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    vim.cmd("StrapsFork -- x")
    assert(#fork_bufs_since(before) == 0, "no fork from a plain buffer")
    assert(notes[#notes]:find("on a straps session buffer", 1, true), notes[#notes])

    provider([==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 800) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "late" } } }
end
]==])
    local s = state.new_session()
    state.append_text(s, "go")
    before = snapshot_bufs()
    loop.start(s)
    vim.api.nvim_set_current_buf(s)
    vim.cmd("StrapsFork -- x")
    assert(#fork_bufs_since(before) == 0, "no fork while a run is active")
    assert(notes[#notes]:find("run active", 1, true), notes[#notes])
    wait_idle(s)

    vim.cmd("StrapsFork abc -- x")
    assert(#fork_bufs_since(before) == 0, "no fork on bad args")
    assert(notes[#notes]:find("usage: :StrapsFork", 1, true), notes[#notes])

    vim.cmd("StrapsFork 1 -- x")
    assert(#fork_bufs_since(before) == 0, "no fork when upto is the system block")
    assert(notes[#notes]:find("at least one message block", 1, true), notes[#notes])
  end)
  vim.notify = real_notify
  assert(ok, err)
end)

it(":StrapsFork with no instruction prompts for one; a cancelled or late prompt forks nothing", function()
  provider(FORK_AWARE_PROVIDER)
  local real_input = vim.ui.input
  local real_notify = vim.notify
  local prompted, pending_cb
  vim.ui.input = function(opts, cb) prompted = opts.prompt; pending_cb = cb end
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
  local ok, err = pcall(function()
    local s = state.new_session()
    state.append_text(s, "go")
    state.append(s, "assistant", nil, "done")
    state.ensure_trailing_user(s)
    vim.api.nvim_set_current_buf(s)
    local before = snapshot_bufs()
    vim.cmd("StrapsFork")
    assert(prompted and prompted:find("fork instruction", 1, true), "should prompt: " .. tostring(prompted))
    pending_cb("typed at the prompt")
    local f = fork_bufs_since(before)[1]
    assert(f, "fork buffer expected")
    wait_idle(f)
    assert(text_of(f):find("typed at the prompt", 1, true), "the prompted text is the instruction")
    vim.cmd("close")

    before = snapshot_bufs()
    vim.cmd("StrapsFork")
    pending_cb(nil)
    assert(#fork_bufs_since(before) == 0, "a cancelled prompt forks nothing")

    -- The source starts a run while the prompt is open: the late answer is refused.
    provider([==[
return function(req, ctx)
  ctx.await(function(resolve) vim.defer_fn(resolve, 500) end)
  return { stop_reason = "end_turn", content = { { type = "text", text = "late" } } }
end
]==])
    vim.cmd("StrapsFork")
    state.append_text(s, "go again")
    loop.start(s)
    pending_cb("too late")
    assert(#fork_bufs_since(before) == 0, "a prompt answered after a run started forks nothing")
    assert(notes[#notes]:find("run active", 1, true), notes[#notes])
    wait_idle(s)
  end)
  vim.ui.input = real_input
  vim.notify = real_notify
  assert(ok, err)
end)
