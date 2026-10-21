# Filters

lulibre has one filter language. `lulibre query`, `&` and `/` in the
interface, and Lua functions such as `lulibre.ids(filter)` all use it.
`lulibre query -h` prints a summary.

    term term ...        all must hold
    a or b               "or" between terms starts an alternative
    -term                negation
    word  "a phrase"     substring of title, authors or tags
    field:value          substring of that field; case and accents are ignored
    field:=value         exact
    field:^value         prefix
    field:~pattern       Lua pattern, case-sensitive, as in string.find
    field:none           the field is empty

Quote a value that contains spaces: `author:="Saunders Mac Lane"`.

In the interface, the status line shows the current filter as `filter …`,
with how many of the library's books match it. `<BS>` shows every book
again.

## Fields

| Field | Matches |
|---|---|
| `title` `author` `tag` `publisher` `series` `lang` `path` | that field |
| `subject` | tags hierarchically: `subject:number-theory` also matches `math/number-theory/additive` |
| `author:unknown` | calibre's placeholder authors |
| `fmt` | file format: `fmt:djvu` |
| `id` `year` | numbers: `12`, `10-20`, `>1990`, `<=2001`, `1,5,9-12` |
| `ident` `doi` `isbn` `arxiv` `url` | identifiers: `doi:10.1007`, `ident:isbn` |
| `text` | full text of the indexed pages; `text:~pattern` for a Lua pattern, `text:=` for raw FTS5 |
| `emb` | metadata embedded in the files themselves |
| `has` `no` | whether something is there: `author tags ids doi isbn arxiv url publisher date series comments lang text file` |
| `is` | states, below |
| `sort` | `[-]id title author year series added modified` |
| `in` | `library` (default), `sync` (files staged from the sync folder), `all` |

## Custom fields

`#name:value` matches a custom field (`:custom`) the way a field term does,
and `=`, `^` and `~` work as above. `#name:none` matches the books without
the field, and so do `no:#name`; `has:#name` matches the books with it.

    #partof:handbook  #part:=3  has:#partof

## `is:`

| | |
|---|---|
| `listauthor` | several authors run together in one name |
| `filetitle` | the title looks like a file name |
| `good` | confirmed as right (`gk`) |
| `noncatalog` | a work no catalogue has a record of (`:noncatalog`) |
| `part` | a part of a whole: a chapter of a handbook, of the Stacks project (`:parts`) |
| `capstitle` | the title is in CAPITALS (`gT` puts it in title case) |
| `indexed` `unindexed` `error` | state of text extraction |
| `missing` | the record's file is not on disk |
| `needsocr` · `ocr` | no usable text layer · text came from OCR |
| `multiformat` | more than one format |
| `marked` | marked in the interface |
| `proposed` | has proposals waiting for review |
| `dupe` | its file is byte-identical to another book's (known once `:dupes` has run) |
| `inlibrary` | a staged file the library already holds |

## Examples

    author:unknown no:tags fmt:pdf
    subject:topology year:1960-1980 sort:year
    text:"spectral sequence" -author:serre
    title:~^%d+%.pdf$                 titles that are a number and ".pdf"
    is:missing or is:error
    in:sync -is:inlibrary             staged files that are new to the library

In the interface, a filter applies to what the list is showing, the library
or the sync folder, unless the filter has `in:`.
