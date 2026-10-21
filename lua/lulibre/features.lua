--- Lists lulibre's optional features and finds the programs they need.
-- lulibre runs without any of these programs. lulibre looks for a program
-- only when a feature that uses it is turned on. A program is found on
-- $PATH, or, with the option pixi_deps = true, in a pixi environment
-- lulibre keeps in its data folder. lulibre offers to add a missing program
-- to that environment, and asks first, since that runs what pixi fetches.
--
-- @module lulibre.features
-- @usage
-- local features = require "lulibre.features"
-- features.list                    -- { {name=, title=, programs=, used_for=, option=, pixi=, packages=} }
-- features.find("pdftotext")       -- its path, or nil
-- features.status(f)               -- { here=, missing = {...}, enabled= }
-- features.need("poppler")         -- the paths of its programs (by name), or nil and how to get them;
--                                  -- may offer to add them to lulibre's pixi environment
-- features.declare{ name=, ... }   -- a script's own feature, listed with the rest
local M = {}

--- The features, each `{ name=, title=, programs=, used_for=, option=, pixi=, packages= }`.
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

--- Declares a script's own feature, which is listed and checked like the
-- built-in features.
-- @tparam table f in the form of an item of `list`
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

--- Returns the folder of lulibre's own pixi environment.
-- @treturn string
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

--- Returns a program's path: on $PATH, or else in lulibre's pixi
-- environment if pixi_deps = true. Returns nil if the program is in neither.
-- @tparam string program
-- @treturn string|nil
function M.find(program)
  for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    if executable(dir .. "/" .. program) then return dir .. "/" .. program end
  end
  if lulibre.o.pixi_deps then
    local p = M.pixi_dir() .. "/.pixi/envs/default/bin/" .. program
    if executable(p) then return p end
  end
  return nil
end

--- Returns true if the feature's option turns it on. The values false,
-- "off", "never", 0 and "" turn a feature off.
local function enabled(f)
  if not f.option then return true end
  local ok, v = pcall(function() return lulibre.o[f.option] end)
  if not ok then return true end
  return not (v == "off" or v == "never" or v == 0 or v == false or v == "")
end

--- Returns whether a feature's programs are here, which ones are missing,
-- and whether the feature's option turns it on.
-- @tparam table f
-- @treturn table `{ here=, missing = {...}, enabled= }`
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

--- Returns one sentence on how to get a feature's programs.
-- @tparam table f
-- @treturn string
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
    s = s .. (lulibre.o.pixi_deps and "; lulibre can add it to its own pixi environment"
      or '; or set pixi_deps = true and lulibre can add it to an environment of its own')
  end
  return s
end

--- Returns the paths of a feature's programs, or nil and how to get them.
-- With pixi_deps = true, if someone can be asked, `need` offers to add the
-- feature to lulibre's pixi environment.
-- @tparam string name
-- @treturn[1] table `{ program = path }`
-- @treturn[2] nil
-- @treturn[2] string how to get them
function M.need(name)
  local f = by_name(name)
  if not f then return nil, "no feature " .. tostring(name) end
  local st = M.status(f)
  if st.here then return st.paths end
  -- a rock: lulibre.require_rock offers to install it (rocks_install = true)
  if f.rock and #(f.programs or {}) == 0 then
    local ok, mod = pcall(lulibre.require_rock, f.modules[1], f.rock)
    if ok then return { [f.modules[1]] = mod } end
    return nil, M.how(f)
  end
  if lulibre.o.pixi_deps and f.pixi and not lulibre.headless and lulibre.task_id() then
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
