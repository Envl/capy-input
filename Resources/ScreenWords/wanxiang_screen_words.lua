-- Rime Sync Screen Words
local screen = require("screen_words")
local wanxiang = require("wanxiang/wanxiang")
return {
  init = function(env)
    env.flypy = wanxiang.get_input_method_type(env) == "flypy"
    if env.flypy then
      screen.init(env)
      env.selected_path = rime_api.get_user_data_dir() .. "/rime-jit-selected-double_pinyin_flypy.tsv"
    end
  end,
  func = function(input, seg, env)
    if env.flypy then screen.func(input, seg, env) end
  end,
  fini = function(env)
    if env.flypy then screen.fini(env) end
  end,
}
