
renv_scope_tempdir <- function(pattern = "renv-tempdir-",
                               tmpdir = tempdir(),
                               umask = NULL,
                               envir = parent.frame())
{
  dir <- renv_scope_tempfile(pattern = pattern, tmpdir = tmpdir, envir = envir)
  ensure_directory(dir, umask = umask)

  renv_scope_wd(dir, envir = envir)
  dir
}

renv_scope_auth <- function(record, envir = parent.frame()) {

  package <- if (is.list(record)) record$Package else record
  auth <- renv_options_override("renv.auth", package, extra = record)

  if (empty(auth))
    return(FALSE)

  envvars <- catch({
    if (is.function(auth))
      auth(record)
    else
      auth
  })

  # warn user if auth appears invalid
  if (inherits(envvars, "error")) {
    warning(envvars)
    return(FALSE)
  }

  if (empty(envvars))
    return(FALSE)

  renv_scope_envvars(list = as.list(envvars), envir = envir)
  return(TRUE)

}

renv_scope_libpaths <- function(new = .libPaths(), envir = parent.frame()) {
  old <- renv_libpaths_set(new)
  defer(renv_libpaths_set(old), envir = envir)
}

renv_scope_options <- function(..., envir = parent.frame()) {
  new <- list(...)
  old <- options(new)
  defer(options(old), envir = envir)
}

renv_scope_locale <- function(category = "LC_ALL", locale = "", envir = parent.frame()) {
  saved <- Sys.getlocale(category)
  Sys.setlocale(category, locale)
  defer(Sys.setlocale(category, saved), envir = envir)
}

renv_scope_envvars <- function(..., list = NULL, envir = parent.frame()) {

  dots <- list %||% list(...)
  old <- as.list(Sys.getenv(names(dots), unset = NA))
  names(old) <- names(dots)

  unset <- map_lgl(dots, is.null)
  Sys.unsetenv(names(dots[unset]))
  if (length(dots[!unset]))
    do.call(Sys.setenv, dots[!unset])

  defer({
    na <- is.na(old)
    Sys.unsetenv(names(old[na]))
    if (length(old[!na]))
      do.call(Sys.setenv, old[!na])
  }, envir = envir)

}

renv_scope_sink <- function(file = nullfile(), envir = parent.frame()) {

  # redirect stdout to file, and redirect stderr back to stdout
  # this ensures that both stdout, stderr are redirected to the same place
  sink(file = file,     type = "output")
  sink(file = stdout(), type = "message")

  defer({
    sink(type = "output")
    sink(type = "message")
  }, envir = envir)

}

renv_scope_error_handler <- function(envir = parent.frame()) {

  error <- getOption("error")
  if (!is.null(error))
    return(FALSE)

  call <- renv_error_handler_call()
  options(error = call)

  defer({
    if (identical(getOption("error"), call))
      options(error = error)
  }, envir = envir)

  TRUE

}

# used to enforce usage of curl 7.64.1 within the
# renv_paths_extsoft folder when available on Windows

# nocov start
renv_scope_downloader <- function(envir = parent.frame()) {

  if (!renv_platform_windows())
    return(FALSE)

  if (nzchar(Sys.which("curl")))
    return(FALSE)

  curlroot <- sprintf("curl-%s-win32-mingw", renv_extsoft_curl_version())
  curl <- renv_paths_extsoft(curlroot, "bin/curl.exe")
  if (!file.exists(curl))
    return(FALSE)

  old <- Sys.getenv("PATH", unset = NA)
  if (is.na(old))
    return(FALSE)

  new <- paste(renv_path_normalize(dirname(curl)), old, sep = .Platform$path.sep)

  renv_scope_envvars(PATH = new, envir = envir)

}
# nocov end

# nocov start
renv_scope_rtools <- function(envir = parent.frame()) {

  if (!renv_platform_windows())
    return(FALSE)

  # check for Rtools
  root <- renv_paths_rtools()
  if (!file.exists(root))
    return(FALSE)

  # get environment variables appropriate for version of Rtools
  vars <- renv_rtools_envvars(root)

  # scope envvars in parent
  renv_scope_envvars(list = vars, envir = envir)

}
# nocov end

# nocov start
renv_scope_install <- function(envir = parent.frame()) {

  if (renv_platform_macos())
    renv_scope_install_macos(envir)

  if (renv_platform_wsl())
    renv_scope_install_wsl(envir)

}

renv_scope_install_macos <- function(envir = parent.frame()) {

  # check that we have command line tools available before invoking
  # R CMD config, as this might fail otherwise
  if (once()) {
    if (!renv_xcode_available()) {
      message("* macOS is reporting that command line tools (CLT) are not installed.")
      message("* Run 'xcode-select --install' to install command line tools.")
      message("* Without CLT, attempts to install packages from sources may fail.")
    }
  }

  # get the current compiler
  args <- c("CMD", "config", "CC")
  cc <- system2(R(), args, stdout = TRUE, stderr = TRUE)

  # check to see if we're using the system toolchain
  # (need to be careful since users might put e.g. ccache or other flags
  # into the CC variable)

  # helper for creating regex matching compiler bits
  matches <- function(pattern) {
    regex <- paste("(?:[[:space:]]|^)", pattern, "(?:[[:space:]]|$)", sep = "")
    grepl(regex, cc)
  }

  sysclang <- case(
    matches("/usr/bin/clang") ~ TRUE,
    matches("clang")          ~ Sys.which("clang") == "/usr/bin/clang",
    FALSE
  )

  # check for an appropriate LLVM toolchain -- if it exists, use it
  spec <- renv_equip_macos_spec()
  if (sysclang && !is.null(spec) && file.exists(spec$dst)) {
    path <- paste(file.path(spec$dst, "bin"), Sys.getenv("PATH"), sep = ":")
    renv_scope_envvars(PATH = path, envir = envir)
  }

  # generate a custom makevars that should better handle compilation
  # with the system toolchain (or other toolchains)
  makevars <- stack()

  # if we don't have an LLVM toolchain available, then try to generate
  # a Makeconf that shields compilation from usages of '-fopenmp'
  if (sysclang) {

    makeconf <- readLines(file.path(R.home("etc"), "Makeconf"), warn = FALSE)
    mplines <- grep(" -fopenmp", makeconf, fixed = TRUE, value = TRUE)

    # read a user makevars (if any)
    contents <- character()
    mvsite <- Sys.getenv(
      "R_MAKEVARS_SITE",
      unset = file.path(R.home("etc"), "Makevars.site")
    )

    if (file.exists(mvsite))
      contents <- readLines(mvsite, warn = FALSE)

    # override usages of '-fopenmp'
    replaced <- gsub(" -fopenmp", "", mplines, fixed = TRUE)
    amended <- unique(c(contents, replaced))
    makevars$push(amended)

  }

  # write makevars to file
  path <- tempfile("Makevars-")
  contents <- unlist(makevars$data(), recursive = TRUE, use.names = FALSE)
  if (length(contents)) {
    writeLines(contents, con = path)
    renv_scope_envvars(R_MAKEVARS_SITE = path, envir = envir)
  }

  TRUE

}

renv_scope_install_wsl <- function(envir = parent.frame()) {
  renv_scope_envvars(R_INSTALL_STAGED = "FALSE")
}
# nocov end

renv_scope_restore <- function(..., envir = parent.frame()) {
  state <- renv_restore_begin(...)
  defer(renv_restore_end(state), envir = envir)
}

renv_scope_git_auth <- function(envir = parent.frame()) {

  # try and tell git to be non-interactive by default
  if (renv_platform_windows()) {
    renv_scope_envvars(
      GIT_TERMINAL_PROMPT = "0",
      envir              = envir
    )
  } else {
    renv_scope_envvars(
      GIT_TERMINAL_PROMPT = "0",
      GIT_ASKPASS         = "/bin/echo",
      envir              = envir
    )
  }

  # use GIT_PAT when provided
  pat <- Sys.getenv("GIT_PAT", unset = NA)
  if (!is.na(pat)) {
    renv_scope_envvars(
      GIT_USERNAME = pat,
      GIT_PASSWORD = "x-oauth-basic",
      envir = envir
    )
  }

  # only set askpass when GIT_USERNAME + GIT_PASSWORD are set
  user <-
    Sys.getenv("GIT_USERNAME", unset = NA) %NA%
    Sys.getenv("GIT_USER",     unset = NA)

  pass <-
    Sys.getenv("GIT_PASSWORD", unset = NA) %NA%
    Sys.getenv("GIT_PASS",     unset = NA)

  if (is.na(user) || is.na(pass))
    return(FALSE)

  askpass <- if (renv_platform_windows())
    system.file("resources/scripts-git-askpass.cmd", package = "renv")
  else
    system.file("resources/scripts-git-askpass.sh", package = "renv")

  renv_scope_envvars(GIT_ASKPASS = askpass, envir = envir)
  return(TRUE)

}

renv_scope_bioconductor <- function(project = NULL,
                                    version = NULL,
                                    envir = parent.frame())
{
  # get current repository
  repos <- getOption("repos")

  # remove old / stale bioc repositories
  stale <- grepl("Bioc", names(repos))
  repos <- repos[!stale]

  # retrieve bioconductor repositories appropriate for this project
  biocrepos <- renv_bioconductor_repos(project = project, version = version)

  # put it all together
  allrepos <- c(repos, biocrepos)

  # activate repositories in this context
  renv_scope_options(repos = renv_vector_unique(allrepos), envir = envir)
}

renv_scope_lock <- function(path = NULL, envir = parent.frame()) {
  renv_lock_acquire(path)
  defer(renv_lock_release(path), envir = envir)
}

renv_scope_trace <- function(what, tracer, envir = parent.frame()) {

  call <- sys.call()
  call[[1L]] <- base::trace
  call[["print"]] <- FALSE
  suppressMessages(eval(call, envir = parent.frame()))

  defer(suppressMessages(untrace(substitute(what))), envir = envir)

}


renv_scope_binding <- function(envir, symbol, replacement, frame = parent.frame()) {
  if (exists(symbol, envir, inherits = FALSE)) {
    old <- renv_binding_replace(symbol, replacement, envir)
    defer(renv_binding_replace(symbol, old, envir), envir = frame)
  } else {
    assign(symbol, replacement, envir = envir)
    defer(rm(list = symbol, envir = envir, inherits = FALSE), envir = frame)
  }
}

renv_scope_tempfile <- function(pattern = "renv-tempfile-",
                                tmpdir  = tempdir(),
                                fileext = "",
                                envir  = parent.frame())
{
  path <- tempfile(pattern, tmpdir, fileext)
  defer(unlink(path, recursive = TRUE, force = TRUE), envir = envir)
  invisible(path)
}

renv_scope_umask <- function(umask, envir = parent.frame()) {
  oldmask <- Sys.umask(umask)
  defer(Sys.umask(oldmask), envir = envir)
  invisible(oldmask)
}

renv_scope_wd <- function(dir = getwd(), envir = parent.frame()) {
  owd <- setwd(dir)
  defer(setwd(owd), envir = envir)
  invisible(owd)
}

renv_scope_sandbox <- function(envir = parent.frame()) {
  sandbox <- renv_sandbox_activate()
  defer(renv_sandbox_deactivate(), envir = envir)
  invisible(sandbox)
}
