-- OpenAlex: records by DOI.
-- Part of lulibre.net: require that, not this (it adds these functions to
-- lulibre.net's table; lulibre/net/core.lua has what they share).
local M = require "lulibre.net.core"
local json = require "lulibre.json"
local unescape, encode = M._unescape, M._encode

-- ---- OpenAlex ----

--- OpenAlex's record for a DOI: title, authors and date, for works CrossRef
-- does not have.
function M.openalex(doi)
  local body, err = M.fetch("openalex", doi:lower(), "https://api.openalex.org/works/doi:" .. encode(doi))
  if not body then return nil, err end
  local ok, w = pcall(json.decode, body)
  if not ok or type(w) ~= "table" or not w.title then return nil, "unreadable reply from OpenAlex" end
  local rec = { title = type(w.title) == "string" and unescape(w.title:gsub("%s+", " ")) or nil, authors = {}, subjects = {},
    ids = { doi = doi }, year = tonumber(w.publication_year), type = w.type, source = "OpenAlex " .. doi,
    date = type(w.publication_date) == "string" and w.publication_date or nil }
  for _, a in ipairs(type(w.authorships) == "table" and w.authorships or {}) do
    if type(a.author) == "table" and type(a.author.display_name) == "string" then
      rec.authors[#rec.authors + 1] = a.author.display_name
    end
  end
  -- where it appeared: the journal, and the house or society behind it
  local place = type(w.primary_location) == "table" and type(w.primary_location.source) == "table" and w.primary_location.source or nil
  if place and type(place.display_name) == "string" and (place.type == nil or place.type == "journal" or place.type == "conference") then
    rec.container = place.display_name
    rec.member = type(place.host_organization_name) == "string" and place.host_organization_name or nil
  end
  -- (no subject is taken from it: OpenAlex sorts works into topics by
  -- machine, and files Wiles's proof of Fermat under mathematical physics)
  return rec
end

return M
