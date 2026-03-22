args <- commandArgs(trailingOnly = TRUE)
target_pkgs <- if (length(args) > 0) args else c("flexsurv", "ggplot2", "dplyr", "readr", "broom")

workspace_lib <- normalizePath("r_libs", mustWork = FALSE)
dir.create(workspace_lib, showWarnings = FALSE, recursive = TRUE)
.libPaths(c(workspace_lib, .libPaths()))

base_pkgs <- rownames(installed.packages(priority = "base"))
rec_pkgs <- rownames(installed.packages(priority = "recommended"))
ignored <- c("R", base_pkgs, rec_pkgs)

strip_version <- function(x) {
  x <- gsub("\n", " ", x, fixed = TRUE)
  x <- gsub("\\(.*?\\)", "", x)
  trimws(x)
}

parse_deps <- function(pkg) {
  desc <- tryCatch(packageDescription(pkg), error = function(e) NULL)
  if (is.null(desc)) {
    return(character(0))
  }
  dep_fields <- desc[c("Depends", "Imports", "LinkingTo")]
  dep_fields <- dep_fields[!is.na(dep_fields)]
  if (length(dep_fields) == 0) {
    return(character(0))
  }
  vals <- unlist(strsplit(paste(dep_fields, collapse = ","), ","))
  vals <- strip_version(vals)
  vals <- vals[nzchar(vals)]
  vals <- vals[!vals %in% c(ignored, "NULL", "NA")]
  unique(vals)
}

resolve_missing <- function(seed_pkgs) {
  seen <- character(0)
  queue <- unique(seed_pkgs)
  missing <- character(0)
  installed <- rownames(installed.packages())

  while (length(queue) > 0) {
    pkg <- queue[[1]]
    queue <- queue[-1]
    if (pkg %in% seen || !(pkg %in% installed)) {
      next
    }
    seen <- c(seen, pkg)
    deps <- parse_deps(pkg)
    pkg_missing <- setdiff(deps, installed)
    missing <- unique(c(missing, pkg_missing))
    queue <- unique(c(queue, setdiff(deps, c(seen, missing))))
  }

  sort(missing)
}

for (i in seq_len(5)) {
  current_missing <- resolve_missing(target_pkgs)
  if (length(current_missing) == 0) {
    cat("No missing dependencies detected.\n")
    quit(status = 0)
  }
  cat(sprintf("Iteration %d missing packages:\n", i))
  cat(paste(current_missing, collapse = "\n"))
  cat("\n")
  install.packages(current_missing, lib = workspace_lib, repos = "https://cloud.r-project.org")
}

final_missing <- resolve_missing(target_pkgs)
if (length(final_missing) > 0) {
  cat("Still missing after bootstrap:\n")
  cat(paste(final_missing, collapse = "\n"))
  cat("\n")
  quit(status = 1)
}

cat("Dependency bootstrap completed.\n")
