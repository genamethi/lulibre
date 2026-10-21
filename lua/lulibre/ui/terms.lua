--- Lists the phrases that mark each subject, as learned from the confirmed
-- records (:learn), so you can review them: drop the ones that don't
-- belong, and add your own.
--
-- @screens lulibre.ui.terms
-- @usage
-- require("lulibre.ui.terms").run()   -- as :terms does
local keys = require("lulibre.ui.keys").of("terms")
local learn = require "lulibre.learn"

local M = {}

--- Opens the list.
-- @tparam[opt] string args a subject to limit the list to
function M.run(args)
  local only = type(args) == "string" and args ~= "" and args or nil
  local at -- row -> { subject=, term= } ; term is nil on a subject's own line
  local show_dropped = false
  local function build()
    local rows = {}
    at = {}
    local last
    for _, r in ipairs(learn.terms(only, show_dropped)) do
      if r.subject ~= last then
        last = r.subject
        local n = lulibre.count(('in:library subject:"%s"'):format(r.subject))
        rows[#rows + 1] = { ("%s     %d book%s"):format(r.subject, n, n == 1 and "" or "s"), style = "head" }
        at[#rows] = { subject = r.subject }
      end
      rows[#rows + 1] = { r.state == "kept" and "+" or r.state == "dropped" and "×" or "", r.term,
        r.state == "learned" and ("%.2f"):format(r.score or 0) or "", r.state == "learned" and (r.books or "") or "",
        r.state == "kept" and "yours" or r.state == "dropped" and "dropped: will not be learned again" or "",
        style = r.state == "kept" and "ok" or r.state == "dropped" and "dim" or nil }
      at[#rows] = { subject = r.subject, term = r.term, state = r.state }
    end
    return rows
  end
  local rows = build()
  if #rows == 0 then
    lulibre.notify(("nothing has been learned%s yet: %s confirms good records, :learn learns from them"):format(
      only and " for " .. only or "", lulibre.hint("good")))
    return
  end
  local function title()
    local last = lulibre.sql("SELECT value FROM kv WHERE key = 'learn:last'")[1]
    local when, books = (last and last.value or ""):match("^(%d+)\t(%d+)")
    return ("marking phrases%s%s"):format(only and "  " .. only or "",
      when and ("   learned %s from %s confirmed books"):format(os.date("%Y-%m-%d", tonumber(when)), books) or "")
  end
  local p <close> = require("lulibre.ui.panels").open("terms", {
    title = title(), help = keys:hint("drop", "add", "find", "learn"), height = 0.5, keys = keys:own(),
    pass = require("lulibre.ui.panels").PASS,
    columns = { { "", 1 }, { "Phrase", -3 }, { "Score", 6 }, { "Books", 6 }, { "", -2 } },
    rows = rows,
  })
  if not p then return end
  p:cursor(2)

  while true do
    local key, row = p:wait()
    if not key then return end
    local it = at[row]
    local act = keys:action(key)
    if act == "help" then
      keys:show("marking phrases")
    elseif it and it.term and act == "drop" then
      -- a dropped phrase stays dropped through later learning; dropping again brings it back
      learn.set(it.subject, it.term, it.state ~= "dropped" and "dropped" or nil)
      if it.state == "dropped" then lulibre.notify(("'%s' may be learned again"):format(it.term)) end
    elseif it and act == "add" then
      local v = lulibre.input { prompt = ("a phrase that marks %s: "):format(it.subject) }
      if v and v:find("%a") then learn.set(it.subject, v, "kept") end
    elseif it and it.term and act == "find" then
      lulibre.filter(('text:"%s"'):format(it.term))
    elseif act == "dropped" then
      show_dropped = not show_dropped
    elseif act == "learn" then
      local st, why = learn.run()
      lulibre.notify(st and ("learned %d phrases for %d subjects from %d confirmed books"):format(st.terms, st.subjects, st.books)
        or why, not st and "error" or nil)
    end
    rows = build()
    if #rows == 0 then return end
    p:rows(rows)
    p:title(title())
  end
end

return M
