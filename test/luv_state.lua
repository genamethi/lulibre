-- Regression: luv callbacks must not depend on the task that first loaded luv.
-- A short task requires luv and ends; a callback firing afterwards used to
-- run on that task's dead coroutine and crash.
lulibre.spawn(function() require "luv" end)
lulibre.sleep(20)
collectgarbage()
collectgarbage()
local uv = require "luv"
local fired = false
local t = uv.new_timer()
t:start(10, 0, function()
  fired = true
  t:close()
end)
lulibre.sleep(60)
collectgarbage()
print("callback fired: " .. tostring(fired))
