-- Features and the programs they need. lulibre needs none of these to run:
-- each comes in when the feature that uses it is turned on, and is looked
-- for then. A program is found on $PATH or, with the option pixi_deps = "on",
-- in an environment lulibre keeps with pixi in its data folder, to which it
-- offers to add a missing one (asking first: that runs what pixi fetches).
--
--   local features = require "lulibre.features"
--   features.list                    -- { {name=, title=, programs=, used_for=, option=, pixi=, packages=} }
--   features.find("pdftotext")       -- its path, or nil
--   features.status(f)               -- { here=, missing = {...}, enabled= }
--   features.need("poppler")         -- the paths of its programs (by name), or nil and how to get them;
--                                    -- may offer to add them to lulibre's pixi environment
--   features.declare{ name=, ... }   -- a script's own feature, listed with the rest
local M = {}

M.list = {
  { name = "poppler", title = "poppler's pdftotext", programs = { "pdftotext" },
    used_for = "reading garbled pages of a PDF again (:run reread, the option text_fallback)",
    option = "text_fallback", pixi = "poppler",
    packages = { pacman = "poppler", apt = "poppler-utils", dnf = "poppler-utils", brew = "poppler" } },
  { name = "tesseract", title = "tesseract OCR", programs = { "tesseract" },
    used_for = "reading the text of scanned pages (:run ocr, the option ocr)",
    option = "ocr", pixi = "tesseract",
    packages = { pacman = "tesseract tesseract-data-eng", apt = "tesseract-ocr", dnf = "tesseract", brew = "tesseract" } },
  { name = "lpeg", title = "LPeg", programs = {}, modules = { "lpeg" }, rock = "lpeg",
    used_for = "grammars of publications written with LPeg patterns (lulibre.grammars)",
    packages = { luarocks = "lpeg (luarocks --lua-version " .. _VERSION:match("%d+%.%d+") .. " install lpeg)" } },
  { name = "ocrmypdf", title = "OCRmyPDF", programs = { "ocrmypdf" },
    used_for = "giving a scanned PDF itself the text OCR reads (the option ocr_write)",
    option = "ocr_write", pixi = "ocrmypdf",
    packages = { pacman = "ocrmypdf", apt = "ocrmypdf", dnf = "ocrmypdf", brew = "ocrmypdf" } },
}

--- A feature of a script's own, listed and looked for like these.
function M.declare(f)
  assert(f.name and (f.programs or f.modules), "a feature has a name and the programs or modules it needs")
  for i, g in ipairs(M.list) do
    if g.name == f.name then
      M.list[i] = f
      return f
    end
  end
  M.list[#M.list + 1] = f
  return f
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

local function by_name(name)
  for _, f in ipairs(M.list) do
    if f.name == name then return f end
  end
  return nil
end

--- The folder of lulibre's own pixi environment.
function M.pixi_dir()
  return lulibre.settings.paths().data_dir .. "/pixi"
end

local function executable(path)
  local ok, uv = pcall(require, "luv")
  if not ok then
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
  end
  return uv.fs_access(path, "X") == true
end

--- Where a program is: on $PATH, else (pixi_deps = "on") in lulibre's
-- pixi environment. nil when it is in neither.
function M.find(program)
  for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    if executable(dir .. "/" .. program) then return dir .. "/" .. program end
  end
  if lulibre.o.pixi_deps == "on" then
    local p = M.pixi_dir() .. "/.pixi/envs/default/bin/" .. program
    if executable(p) then return p end
  end
  return nil
end

--- Is the feature on, by its option? An option whose value is "off",
-- "never" or 0 turns it off.
local function enabled(f)
  if not f.option then return true end
  local ok, v = pcall(function() return lulibre.o[f.option] end)
  if not ok then return true end
  return not (v == "off" or v == "never" or v == 0 or v == false or v == "")
end

function M.status(f)
  if type(f) == "string" then f = by_name(f) end
  local missing, paths = {}, {}
  for _, p in ipairs(f.programs or {}) do
    local at = M.find(p)
    if at then paths[p] = at else missing[#missing + 1] = p end
  end
  -- Lua modules: there when require finds one that loads (one that would crash is refused)
  for _, m in ipairs(f.modules or {}) do
    local ok, mod = pcall(require, m)
    if ok then paths[m] = mod else missing[#missing + 1] = m end
  end
  return { here = #missing == 0, missing = missing, paths = paths, enabled = enabled(f) }
end

--- How to get a feature's programs, in a sentence.
function M.how(f)
  local parts = {}
  for _, k in ipairs { "pacman", "apt", "dnf", "brew", "luarocks" } do
    if f.packages and f.packages[k] then parts[#parts + 1] = ("%s %s"):format(k, f.packages[k]) end
  end
  local names = {}
  for _, p in ipairs(f.programs or {}) do names[#names + 1] = p end
  for _, m in ipairs(f.modules or {}) do names[#names + 1] = "the Lua module " .. m end
  local s = ("%s is not installed (%s)"):format(table.concat(names, ", "), table.concat(parts, "; "))
  if f.pixi then
    s = s .. (lulibre.o.pixi_deps == "on" and "; lulibre can add it to its own pixi environment"
      or '; or set pixi_deps = "on" and lulibre can add it to an environment of its own')
  end
  return s
end

--- The feature's programs, found ({ name = path }), or nil and how to get
-- them. With pixi_deps = "on", where someone can be asked, it offers to add
-- the feature to lulibre's pixi environment.
function M.need(name)
  local f = by_name(name)
  if not f then return nil, "no feature " .. tostring(name) end
  local st = M.status(f)
  if st.here then return st.paths end
  -- a rock: lulibre.require_rock offers to install it (rocks_install = "on")
  if f.rock and #(f.programs or {}) == 0 then
    local ok, mod = pcall(lulibre.require_rock, f.modules[1], f.rock)
    if ok then return { [f.modules[1]] = mod } end
    return nil, M.how(f)
  end
  if lulibre.o.pixi_deps == "on" and f.pixi and not lulibre.headless and lulibre.task_id() then
    local pixi = M.find("pixi")
    if pixi and lulibre.confirm(("%s needs %s; add %s to lulibre's pixi environment (%s)? pixi fetches it from conda-forge"):format(
        f.used_for, table.concat(st.missing, ", "), f.pixi, M.pixi_dir())) then
      local dir = M.pixi_dir()
      lulibre.progress("pixi: adding " .. f.pixi)
      if not exists(dir .. "/pixi.toml") then
        lulibre.system({ "mkdir", "-p", dir })
        lulibre.system({ pixi, "init", dir }, { timeout = 120000 })
      end
      local r, err = lulibre.system({ pixi, "add", "--manifest-path", dir .. "/pixi.toml", f.pixi }, { timeout = 900000 })
      lulibre.progress(nil)
      if not r or r.code ~= 0 then return nil, "pixi could not add " .. f.pixi .. ": " .. tostring(err or (r and r.stderr)) end
      st = M.status(f)
      if st.here then return st.paths end
    end
  end
  return nil, M.how(f)
end

return M
