-- The Lua modules lulibre needs at run time. Installed by make rocks.
rockspec_format = "3.0"
package = "lulibre"
version = "dev-1"
source = {
  url = "git+https://github.com/genamethi/lulibre.git",
}
description = {
  summary = "A terminal interface for fixing the metadata of a calibre library",
  homepage = "https://github.com/genamethi/lulibre",
  license = "Apache-2.0 WITH LLVM-exception",
}
dependencies = {
  "lua >= 5.4, < 5.6",
  "luv",
  "dkjson",
  "lpeg",
}
build = {
  type = "none",
}
