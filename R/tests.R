
`_renv_tests_root` <- NULL

renv_tests_running <- function() {
  getOption("renv.tests.running", default = FALSE)
}

renv_test_code <- function(code, data = list(), fileext = ".R", envir = parent.frame()) {
  code <- do.call(substitute, list(substitute(code), data))
  file <- renv_scope_tempfile("renv-code-", fileext = fileext, envir = envir)

  writeLines(deparse(code), con = file)
  file
}

renv_test_retrieve <- function(record) {

  renv_scope_error_handler()

  # avoid using cache
  cache_path <- renv_scope_tempfile()
  renv_scope_envvars(RENV_PATHS_CACHE = cache_path)

  # construct records
  package <- record$Package
  records <- list(record)
  names(records) <- package

  # prepare dummy library
  templib <- renv_scope_tempfile("renv-library-")
  ensure_directory(templib)
  renv_scope_libpaths(c(templib, .libPaths()))

  # attempt a restore into that library
  renv_scope_restore(
    project = getwd(),
    library = templib,
    records = records,
    packages = package,
    recursive = FALSE
  )

  records <- retrieve(record$Package)
  renv_install_impl(records)

  descpath <- file.path(templib, package)
  if (!file.exists(descpath))
    stopf("failed to retrieve package '%s'", package)

  desc <- renv_description_read(descpath)
  fields <- grep("^Remote", names(record), value = TRUE)

  testthat::expect_identical(
    as.list(desc[fields]),
    as.list(record[fields])
  )

}

renv_tests_diagnostics <- function() {

  # print library paths
  renv_pretty_print(
    paste("-", .libPaths()),
    "The following R libraries are set:",
    wrap = FALSE
  )

  # print repositories
  repos <- getOption("repos")
  renv_pretty_print(
    paste(names(repos), repos, sep = ": "),
    "The following repositories are set:",
    wrap = FALSE
  )

  # print renv root
  renv_pretty_print(
    paste("-", paths$root()),
    "The following renv root directory is being used:",
    wrap = FALSE
  )

  # print cache root
  renv_pretty_print(
    paste("-", paths$cache()),
    "The following renv cache directory is being used:",
    wrap = FALSE
  )

  writeLines("The following packages are available in the test repositories:")

  dbs <-
    available_packages(type = "source", quiet = TRUE) %>%
    map(function(db) {
      rownames(db) <- NULL
      db[c("Package", "Version", "File")]
    })

  print(dbs)

  path <- Sys.getenv("PATH")
  splat <- strsplit(path, .Platform$path.sep, fixed = TRUE)[[1]]

  renv_pretty_print(
    paste("-", splat),
    "The following PATH is set:",
    wrap = FALSE
  )

  envvars <- c(
    grep("^_R_", names(Sys.getenv()), value = TRUE),
    "HOME",
    "R_ARCH", "R_HOME",
    "R_LIBS", "R_LIBS_SITE", "R_LIBS_USER", "R_USER",
    "R_ZIPCMD",
    "TAR", "TEMP", "TMP", "TMPDIR"
  )

  keys <- format(envvars)
  vals <- Sys.getenv(envvars, unset = "<NA>")
  vals[vals != "<NA>"] <- renv_json_quote(vals[vals != "<NA>"])

  renv_pretty_print(
    paste(keys, vals, sep = " : "),
    "The following environment variables of interest are set:",
    wrap = FALSE
  )

}

renv_tests_root <- function() {
  `_renv_tests_root` <<- `_renv_tests_root` %||% {
    normalizePath(testthat::test_path("."), winslash = "/")
  }
}

renv_tests_path <- function(path = NULL) {

  # special case for NULL path
  if (is.null(path))
    return(renv_tests_root())

  # otherwise, form path from root
  file.path(renv_tests_root(), path)

}

renv_tests_supported <- function() {

  # supported when running locally + on CI
  for (envvar in c("NOT_CRAN", "CI"))
    if (renv_envvar_exists(envvar))
      return(TRUE)

  # disabled on older macOS releases (credentials fails to load)
  if (renv_platform_macos() && getRversion() < "4.0.0")
    return(FALSE)

  # disabled on Windows
  if (renv_platform_windows())
    return(FALSE)

  # true otherwise
  TRUE

}
