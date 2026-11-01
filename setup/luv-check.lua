-- Says whether luv loads under lulibre's own Lua and package path.
local ok, err = pcall(require, "luv")
if ok then
  print("luv loads: " .. (package.searchpath("luv", package.cpath) or "built in"))
else
  error("luv is not on the package path: " .. tostring(err):match("^[^\n]*"), 0)
end
