#!/usr/bin/env Rscript
#
# check-drift.R -- verify that this book still describes the bmm it claims to.
#
# Two passes:
#
#   Pass 1 (anchors). Every fenced R block that carries a `bmm-src=` attribute
#     names one or more top-level definitions. Each is resolved against the same
#     name in bmm's R/ directory and compared after normalization. A block
#     marked `bmm-excerpt="abridged"` must still RESOLVE but its body is not
#     compared, because it elides on purpose.
#
#   Pass 2 (prose). Package paths and bmm-convention identifiers mentioned in
#     prose are checked for existence. This catches the renamed-file class of
#     error (`R/bmm_model_sdmSimple.R`) that a reader hits by clicking.
#
# An anchor that fails to RESOLVE is an error, never a skip. Silent skipping on
# rename is how grep-based checkers stop working without anyone noticing.
#
# Requires only base R. It reads a bmm git checkout's source text and never
# loads or installs the package, because the installed bmm may be a personal
# fork ahead of any release.
#
# Usage:
#   Rscript tools/check-drift.R                     # bmm at ../bmm, ref from index.qmd
#   Rscript tools/check-drift.R --bmm ../bmm        # explicit checkout
#   Rscript tools/check-drift.R --ref develop       # check against another ref
#   Rscript tools/check-drift.R --ref WORKTREE      # check the checkout as-is
#   BMM_DIR=/path/to/bmm Rscript tools/check-drift.R

# ---- arguments ---------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[[i + 1L]]
}

notes_dir <- normalizePath(".", mustWork = TRUE)
bmm_dir <- arg_value("--bmm", Sys.getenv("BMM_DIR", "../bmm"))
ref <- arg_value("--ref", NA_character_)

failures <- character(0)
notes <- character(0)
fail <- function(...) failures <<- c(failures, paste0(...))
note <- function(...) notes <<- c(notes, paste0(...))

# ---- the ref to check against -----------------------------------------------

# Default to the version the book claims, so the notes are not permanently red
# on unreleased work in bmm's develop branch.
claimed_version <- function() {
  index <- file.path(notes_dir, "index.qmd")
  if (!file.exists(index)) return(NA_character_)
  m <- regmatches(
    paste(readLines(index, warn = FALSE), collapse = "\n"),
    regexpr("\\*\\*v[0-9]+\\.[0-9]+\\.[0-9]+\\*\\*", paste(readLines(index, warn = FALSE), collapse = "\n"))
  )
  if (!length(m)) return(NA_character_)
  gsub("\\*", "", m)
}

if (is.na(ref)) {
  ref <- claimed_version()
  if (is.na(ref)) {
    fail("Could not read the claimed bmm version from index.qmd. Pass --ref explicitly.")
    ref <- "WORKTREE"
  }
}

if (!dir.exists(bmm_dir)) {
  cat("FAIL: no bmm checkout at '", bmm_dir, "'.\n",
    "      Pass --bmm <path> or set BMM_DIR.\n",
    sep = ""
  )
  quit(status = 2L)
}
bmm_dir <- normalizePath(bmm_dir, mustWork = TRUE)

# Read the package source at `ref` into a temporary directory, so the check is
# independent of whatever branch the checkout happens to be sitting on.
read_pkg_at_ref <- function(bmm_dir, ref) {
  if (identical(ref, "WORKTREE")) {
    return(bmm_dir)
  }
  dest <- file.path(tempdir(), paste0("bmm-", gsub("[^A-Za-z0-9._-]", "_", ref)))
  unlink(dest, recursive = TRUE)
  dir.create(dest, recursive = TRUE)
  status <- system2(
    "git",
    c("-C", shQuote(bmm_dir), "archive", shQuote(ref)),
    stdout = file.path(dest, "pkg.tar"), stderr = FALSE
  )
  if (!identical(status, 0L)) {
    return(NULL)
  }
  utils::untar(file.path(dest, "pkg.tar"), exdir = dest)
  dest
}

pkg_root <- read_pkg_at_ref(bmm_dir, ref)
if (is.null(pkg_root)) {
  cat("FAIL: '", ref, "' is not a ref in ", bmm_dir, ".\n", sep = "")
  quit(status = 2L)
}
pkg_r <- file.path(pkg_root, "R")
if (!dir.exists(pkg_r)) {
  cat("FAIL: no R/ directory in bmm at ref '", ref, "'.\n", sep = "")
  quit(status = 2L)
}

# ---- extracting definitions from source text --------------------------------

# Normalize by re-deparsing: this makes the comparison insensitive to
# whitespace, comments and quote style, which is what we want. It IS sensitive
# to brace style, so an excerpt must match the source's braces.
normalize <- function(code) {
  parsed <- tryCatch(parse(text = code, keep.source = FALSE), error = function(e) NULL)
  if (is.null(parsed) || length(parsed) == 0L) return(NA_character_)
  paste(
    vapply(
      parsed,
      function(x) paste(deparse(x, width.cutoff = 500L), collapse = "\n"),
      character(1)
    ),
    collapse = "\n"
  )
}

# Top-level `name <- value` assignments, as a named list of deparsed values.
top_level_defs <- function(code) {
  parsed <- tryCatch(parse(text = code, keep.source = FALSE), error = function(e) NULL)
  if (is.null(parsed)) return(list())
  out <- list()
  for (expr in parsed) {
    if (!is.call(expr) || length(expr) != 3L) next
    if (!as.character(expr[[1L]])[1L] %in% c("<-", "=")) next
    name <- tryCatch(as.character(expr[[2L]]), error = function(e) character(0))
    if (length(name) != 1L) next
    out[[name]] <- paste(deparse(expr[[3L]], width.cutoff = 500L), collapse = "\n")
  }
  out
}

pkg_defs <- list()
for (f in list.files(pkg_r, pattern = "\\.R$", full.names = TRUE)) {
  defs <- top_level_defs(paste(readLines(f, warn = FALSE), collapse = "\n"))
  for (name in names(defs)) {
    pkg_defs[[name]] <- list(body = defs[[name]], file = file.path("R", basename(f)))
  }
}

# ---- fenced blocks ----------------------------------------------------------

# Returns one record per fenced block: its start line, its attribute string and
# its content.
fenced_blocks <- function(path) {
  lines <- readLines(path, warn = FALSE)
  opens <- grep("^```[^`]*$", lines)
  out <- list()
  i <- 1L
  while (i <= length(opens)) {
    open <- opens[[i]]
    closes <- opens[opens > open]
    if (!length(closes)) break
    close <- closes[[1L]]
    out[[length(out) + 1L]] <- list(
      line = open,
      attrs = sub("^```", "", lines[[open]]),
      code = paste(lines[seq_len(max(0L, close - open - 1L)) + open], collapse = "\n")
    )
    i <- match(close, opens) + 1L
    if (is.na(i)) break
  }
  out
}

attr_value <- function(attrs, key) {
  m <- regmatches(attrs, regexpr(paste0(key, '="[^"]*"'), attrs))
  if (!length(m)) return(NA_character_)
  sub(paste0('^', key, '="(.*)"$'), "\\1", m)
}

qmds <- list.files(notes_dir, pattern = "\\.qmd$", full.names = TRUE)

# ---- pass 1: anchored excerpts ----------------------------------------------

n_checked <- 0L
n_abridged <- 0L

for (qmd in qmds) {
  for (block in fenced_blocks(qmd)) {
    src <- attr_value(block$attrs, "bmm-src")
    if (is.na(src)) next
    where <- paste0(basename(qmd), ":", block$line)
    declared_file <- attr_value(block$attrs, "filename")
    abridged <- identical(attr_value(block$attrs, "bmm-excerpt"), "abridged")
    names_wanted <- trimws(strsplit(src, ",")[[1L]])
    block_defs <- top_level_defs(block$code)

    for (name in names_wanted) {
      # Resolution failure is always an error.
      if (is.null(pkg_defs[[name]])) {
        fail(
          where, ": bmm-src=\"", name, "\" does not resolve -- no top-level ",
          "definition of that name in bmm R/ at ", ref, ". Renamed or removed?"
        )
        next
      }
      if (!is.na(declared_file) && !identical(declared_file, pkg_defs[[name]]$file)) {
        fail(
          where, ": filename=\"", declared_file, "\" but '", name,
          "' is defined in ", pkg_defs[[name]]$file, " at ", ref, "."
        )
      }
      if (abridged) {
        n_abridged <- n_abridged + 1L
        next
      }
      if (is.null(block_defs[[name]])) {
        fail(
          where, ": bmm-src=\"", name, "\" is anchored but the block contains ",
          "no top-level definition of that name."
        )
        next
      }
      n_checked <- n_checked + 1L
      excerpt <- normalize(block_defs[[name]])
      source <- normalize(pkg_defs[[name]]$body)
      if (!identical(excerpt, source)) {
        fail(
          where, ": '", name, "' differs from ", pkg_defs[[name]]$file,
          " at ", ref, " (excerpt ", nchar(excerpt), " chars, source ",
          nchar(source), "). Update the excerpt, or mark it ",
          'bmm-excerpt="abridged" if it elides on purpose.'
        )
      }
    }
  }
}

# Every R block without an anchor is reported, not failed: the book has display
# blocks that are not excerpts (user-facing examples, generated template
# output, Stan code).
n_unanchored <- 0L
for (qmd in qmds) {
  for (block in fenced_blocks(qmd)) {
    if (!grepl("^ *\\{?\\.?r\\b", block$attrs)) next
    if (!is.na(attr_value(block$attrs, "bmm-src"))) next
    resolvable <- intersect(names(top_level_defs(block$code)), names(pkg_defs))
    if (length(resolvable)) {
      n_unanchored <- n_unanchored + 1L
      note(
        basename(qmd), ":", block$line, ": unanchored block defines ",
        paste(resolvable, collapse = ", "),
        ", which also exists in bmm. Consider adding bmm-src."
      )
    }
  }
}

# ---- pass 2: prose ----------------------------------------------------------

# Returns the prose lines with their original file line numbers attached, so a
# failure can point at a line the reader can open.
prose_of <- function(path) {
  lines <- readLines(path, warn = FALSE)
  fences <- grep("^```", lines)
  drop <- logical(length(lines))
  if (length(fences) >= 2L) {
    for (k in seq(1L, length(fences) - 1L, by = 2L)) {
      drop[fences[[k]]:fences[[k + 1L]]] <- TRUE
    }
  }
  list(text = lines[!drop], line = which(!drop))
}

# Package paths named in backticks must exist in the package at `ref`.
path_pattern <- "`((?:R|inst|tests|man|vignettes)/[A-Za-z0-9._/*{}<>-]+)`"

for (qmd in qmds) {
  prose <- prose_of(qmd)
  for (i in seq_along(prose$text)) {
    line <- prose$text[[i]]
    at <- prose$line[[i]]
    m <- regmatches(line, gregexpr(path_pattern, line, perl = TRUE))[[1L]]
    for (hit in m) {
      p <- gsub("`", "", hit)
      # Skip templates and globs -- they name a shape, not a file.
      if (grepl("[*{}<>]", p)) next
      if (grepl("_name_of_your_model|model_name|my_model|mymodel|gcm|abc", p)) next
      if (!file.exists(file.path(pkg_root, p)) && !dir.exists(file.path(pkg_root, p))) {
        fail(
          basename(qmd), ":", at, ": prose names '", p,
          "' which does not exist in bmm at ", ref, "."
        )
      }
    }
  }
}

# bmm-convention identifiers named in backticks must exist. Deliberately narrow:
# requiring every backticked `foo()` to exist flags 18 of 43 in this book, all
# false positives.
ident_patterns <- c(
  "^\\.model_",
  "^\\..*_defaults$",
  "^\\..*_version_table$",
  "^(check_data|configure_model|configure_prior|check_formula|create_initfun|bmf2bf|postprocess_brm)\\."
)

# Names the book legitimately invents for its worked examples.
example_names <- paste(
  "gcm", "my_new_model", "mymodel", "my_model", "modelname", "model_name",
  "abc$", "\\.\\.\\.",
  # a bare prefix names the convention itself, not a definition
  "^\\.model_$", "^\\.$",
  sep = "|"
)

for (qmd in qmds) {
  prose <- prose_of(qmd)
  for (i in seq_along(prose$text)) {
    line <- prose$text[[i]]
    at <- prose$line[[i]]
    m <- regmatches(line, gregexpr("`[.A-Za-z][A-Za-z0-9._]*(\\(\\))?`", line))[[1L]]
    for (hit in m) {
      id <- gsub("[`()]", "", hit)
      if (!any(vapply(ident_patterns, grepl, logical(1), x = id))) next
      if (grepl(example_names, id)) next
      # A method may be defined anywhere; accept it if any R file defines it.
      if (is.null(pkg_defs[[id]])) {
        fail(
          basename(qmd), ":", at, ": prose names '", id,
          "' which matches a bmm naming convention but is not defined in bmm at ",
          ref, "."
        )
      }
    }
  }
}

# ---- report -----------------------------------------------------------------

cat("check-drift: bmm ", basename(bmm_dir), " at ref ", ref, "\n", sep = "")
cat("  anchored excerpts compared: ", n_checked, "\n", sep = "")
cat("  anchored excerpts abridged (resolved, body not compared): ", n_abridged, "\n", sep = "")
cat("  unanchored blocks that could be anchored: ", n_unanchored, "\n", sep = "")

if (length(notes)) {
  cat("\nNotes:\n")
  cat(paste0("  - ", notes, collapse = "\n"), "\n", sep = "")
}

if (length(failures)) {
  cat("\nFAILURES (", length(failures), "):\n", sep = "")
  cat(paste0("  - ", failures, collapse = "\n"), "\n", sep = "")
  quit(status = 1L)
}

cat("\nOK: no drift detected.\n")
