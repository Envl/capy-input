-- Capy Companion Auto Switch
-- Remembers and restores Rime ascii_mode (EN/ZH) per window.
local M = {}
local kNoop = 2
local state_counter = 0

local function is_enabled(env)
  local file = io.open(env.enabled, "r")
  if not file then return false end
  file:close()
  return true
end

local function write_state(env, ascii)
  state_counter = state_counter + 1
  local tmp = env.state .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then return end
  file:write((ascii and "1" or "0") .. "\t" .. tostring(state_counter) .. "\n")
  file:close()
  os.rename(tmp, env.state)
end

local function read_target(env)
  local file = io.open(env.target, "r")
  if not file then return nil, nil end
  local line = file:read("*l")
  file:close()
  if not line then return nil, nil end
  return line:match("^([^\t]+)\t([01%-])$")
end

local function apply_target(env, ctx, is_printable)
  if not is_enabled(env) then return end
  local seq, mode = read_target(env)
  if not seq or seq == env.last_seq then return end
  if mode == "1" or mode == "0" then
    env.last_seq = seq
    local desired = (mode == "1")
    if ctx:get_option("ascii_mode") ~= desired then
      env.applying = true
      ctx:set_option("ascii_mode", desired)
      env.applying = false
    end
  elseif mode == "-" and is_printable then
    env.last_seq = seq
    write_state(env, ctx:get_option("ascii_mode"))
  end
end

function M.init(env)
  local base = (os.getenv("HOME") or "") .. "/Library/Caches/CapyAutoSwitch"
  env.enabled = base .. "/enabled"
  env.target = base .. "/target"
  env.state = base .. "/state"
  env.last_seq = nil
  env.applying = false
  local ctx = env.engine.context
  env.option_conn = ctx.option_update_notifier:connect(function(context, name)
    if name ~= "ascii_mode" or env.applying or not is_enabled(env) then return end
    write_state(env, context:get_option("ascii_mode"))
  end)
  apply_target(env, ctx, false)
end

function M.fini(env)
  if env.option_conn then
    env.option_conn:disconnect()
    env.option_conn = nil
  end
end

function M.func(key, env)
  if key:release() then return kNoop end
  local printable = not key:ctrl() and not key:alt() and not key:super()
    and key.keycode >= 0x20 and key.keycode <= 0x7e
  apply_target(env, env.engine.context, printable)
  return kNoop
end

return M
