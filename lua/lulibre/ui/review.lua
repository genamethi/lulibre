--- The review view (design 16, 18, 33, 34).
--
-- One proposal per row; space cycles a row through its alternatives. The
-- task that opens the view owns the view and pulls its events: the row
-- shown and the alternative in view live in the task's locals. "Records
-- changed" for a book in view re-ranks the book's rows.
--
-- @library lulibre.ui.review
local M = {}

--- Opens the view on books' proposals, and returns when the view closes.
-- @tparam {integer,...} books
function M.open(books)
  error("not written yet", 2)
end

return M
