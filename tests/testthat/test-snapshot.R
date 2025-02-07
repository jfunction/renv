
test_that("snapshot is idempotent", {

  renv_tests_scope("oatmeal")

  init(bare = TRUE)
  install("oatmeal")
  snapshot()
  before <- renv_lockfile_read("renv.lock")
  snapshot()
  after <- renv_lockfile_read("renv.lock")
  expect_equal(before, after)

})

test_that("snapshot failures are reported", {

  renv_scope_envvars(RENV_PATHS_ROOT = renv_scope_tempfile())
  renv_tests_scope("oatmeal")
  init()

  descpath <- system.file("DESCRIPTION", package = "oatmeal")
  unlink(descpath)
  expect_snapshot(snapshot())

})

test_that("broken symlinks are reported", {
  skip_on_os("windows")

  renv_scope_envvars(RENV_PATHS_ROOT = renv_scope_tempfile())
  renv_tests_scope("oatmeal")
  init()

  oatmeal <- renv_path_normalize(system.file(package = "oatmeal"), winslash = "/")
  unlink(oatmeal, recursive = TRUE)
  expect_snapshot(snapshot())

})

test_that("multiple libraries can be used when snapshotting", {

  renv_scope_envvars(RENV_PATHS_ROOT = renv_scope_tempfile())
  renv_tests_scope()

  init()

  lib1 <- renv_scope_tempfile("renv-lib1-")
  lib2 <- renv_scope_tempfile("renv-lib2-")
  ensure_directory(c(lib1, lib2))

  oldlibpaths <- .libPaths()
  .libPaths(c(lib1, lib2))

  install("bread", library = lib1)
  breadloc <- find.package("bread")
  expect_true(renv_file_same(dirname(breadloc), lib1))

  install("toast", library = lib2)
  toastloc <- find.package("toast")
  expect_true(renv_file_same(dirname(toastloc), lib2))

  libs <- c(lib1, lib2)
  lockfile <- snapshot(lockfile = NULL, library = libs, type = "all")
  records <- renv_lockfile_records(lockfile)

  expect_length(records, 2L)
  expect_setequal(names(records), c("bread", "toast"))

  .libPaths(oldlibpaths)

})

test_that("implicit snapshots only include packages currently used", {

  renv_tests_scope("oatmeal")
  init()

  # install toast, but don't declare that we use it
  install("toast")
  lockfile <- snapshot(type = "implicit", lockfile = NULL)
  records <- renv_lockfile_records(lockfile)
  expect_length(records, 1L)
  expect_setequal(names(records), "oatmeal")

  # use toast
  writeLines("library(toast)", con = "toast.R")
  lockfile <- snapshot(type = "packrat", lockfile = NULL)
  records <- renv_lockfile_records(lockfile)
  expect_length(records, 3L)
  expect_setequal(names(records), c("oatmeal", "bread", "toast"))

})

test_that("explicit snapshots only capture packages in DESCRIPTION", {

  renv_tests_scope("breakfast")
  init()

  desc <- list(Type = "Project", Depends = "toast")

  write.dcf(desc, file = "DESCRIPTION")
  lockfile <- snapshot(type = "explicit", lockfile = NULL)
  records <- renv_lockfile_records(lockfile)
  expect_true(length(records) == 2L)
  expect_true(!is.null(records[["bread"]]))
  expect_true(!is.null(records[["toast"]]))

})

test_that("a custom snapshot filter can be used", {
  skip_on_cran()
  renv_tests_scope("breakfast")

  settings$snapshot.type("custom")
  filter <- function(project) c("bread", "toast")
  renv_scope_options(renv.snapshot.filter = filter)

  init()
  lockfile <- renv_lockfile_load(project = getwd())
  expect_setequal(names(renv_lockfile_records(lockfile)), c("bread", "toast"))

})

test_that("snapshotted packages from CRAN include the Repository field", {

  renv_tests_scope("bread")
  init()

  lockfile <- renv_lockfile_read("renv.lock")
  records <- renv_lockfile_records(lockfile)
  expect_true(records$bread$Repository == "CRAN")

})

test_that("snapshot failures due to bad library / packages are reported", {

  renv_tests_scope()
  ensure_directory("badlib/badpkg")
  writeLines("invalid", "badlib/badpkg/DESCRIPTION")
  expect_error(snapshot(library = "badlib"))

})

test_that("snapshot ignores own package in package development scenarios", {

  renv_tests_scope()
  ensure_directory("bread")
  renv_scope_wd("bread")

  writeLines(c("Type: Package", "Package: bread"), con = "DESCRIPTION")

  ensure_directory("R")
  writeLines("function() { library(bread) }", con = "R/deps.R")

  lockfile <- snapshot(lockfile = NULL)
  records <- renv_lockfile_records(lockfile)
  expect_true(is.null(records[["bread"]]))

})

test_that("snapshot warns about unsatisfied dependencies", {

  renv_tests_scope("toast")
  init(settings = list(use.cache = FALSE))

  descpath <- system.file("DESCRIPTION", package = "toast")
  toast <- renv_description_read(descpath)
  toast$Depends <- "bread (> 1.0.0)"
  renv_dcf_write(toast, file = descpath)

  expect_snapshot(snapshot(), error = TRUE)

})

test_that("snapshot records packages discovered in cellar", {

  renv_tests_scope("skeleton")
  renv_scope_envvars(
    RENV_PATHS_CACHE = renv_scope_tempfile(),
    RENV_PATHS_LOCAL = renv_tests_path("local")
  )

  init(bare = TRUE)

  record <- list(Package = "skeleton", Version = "1.0.1")
  records <- install(list(record))

  # validate the record in the lockfile
  lockfile <- snapshot(lockfile = NULL)
  records <- renv_lockfile_records(lockfile)
  skeleton <- records[["skeleton"]]

  expect_equal(skeleton$Package, "skeleton")
  expect_equal(skeleton$Version, "1.0.1")
  expect_equal(skeleton$Source, "Cellar")

})

test_that("snapshot prefers RemoteType to biocViews", {

  desc <- list(
    Package = "test",
    Version = "1.0",
    RemoteType = "github",
    biocViews = "Biology"
  )

  descfile <- renv_scope_tempfile()
  renv_dcf_write(desc, file = descfile)
  record <- renv_snapshot_description(descfile)
  expect_identical(record$Source, "GitHub")

})

test_that("parse errors cause snapshot to abort", {

  renv_tests_scope()

  # write invalid code to an R file
  writeLines("parse error", con = "parse-error.R")

  # init should succeed even with parse errors
  init(bare = TRUE)

  # snapshots should fail when configured to do so
  renv_scope_options(renv.config.dependency.errors = "fatal")
  expect_error(snapshot())

})

test_that("records for packages available on other OSes are preserved", {
  skip_on_os("windows")
  renv_tests_scope("unixonly")

  init()

  # fake a windows-only record
  lockfile <- renv_lockfile_read("renv.lock")
  lockfile$Packages$windowsonly <- lockfile$Packages$unixonly
  lockfile$Packages$windowsonly$Package <- "windowsonly"
  lockfile$Packages$windowsonly$Hash <- NULL
  lockfile$Packages$windowsonly$OS_type <- "windows"
  renv_lockfile_write(lockfile, "renv.lock")

  # call snapshot to update lockfile
  snapshot()

  # ensure that 'windowsonly' is still preserved
  lockfile <- renv_lockfile_read("renv.lock")
  expect_true(!is.null(lockfile$Packages$windowsonly))

})

test_that(".renvignore works during snapshot without an explicit root", {

  renv_tests_scope()

  # install bread
  install("bread")

  # create sub-directory that should be ignored
  dir.create("ignored")
  writeLines("library(bread)", con = "ignored/script.R")

  lockfile <- snapshot(project = ".", lockfile = NULL)
  expect_false(is.null(lockfile$Packages$bread))

  writeLines("*", con = "ignored/.renvignore")

  lockfile <- snapshot(project = ".", lockfile = NULL)
  expect_true(is.null(lockfile$Packages$bread))

})

test_that("snapshot(packages = ...) captures package dependencies", {

  renv_tests_scope("breakfast")

  # init to install required packages
  init()

  # remove old lockfile
  unlink("renv.lock")

  # create lockfile
  snapshot(packages = "breakfast")

  # check for expected records
  lockfile <- renv_lockfile_load(project = getwd())
  records <- renv_lockfile_records(lockfile)

  expect_true(!is.null(records$breakfast))
  expect_true(!is.null(records$bread))
  expect_true(!is.null(records$toast))
  expect_true(!is.null(records$oatmeal))

})

test_that("snapshot() accepts relative library paths", {

  renv_tests_scope("breakfast")

  # initialize project
  init()

  # remove lockfile
  unlink("renv.lock")

  # form relative path to library
  library <- substring(.libPaths()[1], nchar(getwd()) + 2)

  # try to snapshot with relative library path
  snapshot(library = library)

  # test that snapshot succeeded
  expect_true(file.exists("renv.lock"))

})

test_that("snapshot(update = TRUE) preserves old records", {

  renv_tests_scope("breakfast")
  init()

  # remove breakfast, then try to snapshot again
  old <- renv_lockfile_read("renv.lock")
  remove("breakfast")
  snapshot(update = TRUE)
  new <- renv_lockfile_read("renv.lock")

  expect_identical(names(old$Packages), names(new$Packages))

  # try installing a package
  old <- renv_lockfile_read("renv.lock")
  writeLines("library(halloween)", con = "halloween.R")
  install("halloween")
  snapshot(update = TRUE)
  new <- renv_lockfile_read("renv.lock")

  # check that we have our old record names
  expect_true(all(old$Packages %in% new$Packages))

  # now try removing 'breakfast'
  snapshot(update = FALSE)
  new <- renv_lockfile_read("renv.lock")
  expect_false("breakfast" %in% names(new$Packages))

})

test_that("renv reports missing packages in explicit snapshots", {

  renv_tests_scope()
  init()

  writeLines("Depends: breakfast", con = "DESCRIPTION")
  expect_snapshot(snapshot(type = "explicit"))

})

test_that("a project using explicit snapshots is marked in sync appropriately", {

  skip_on_cran()
  renv_tests_scope()
  renv_scope_options(renv.config.snapshot.type = "explicit")

  init()

  writeLines("Depends: breakfast", con = "DESCRIPTION")
  expect_false(status()$synchronized)

  install("breakfast")
  expect_false(status()$synchronized)

  snapshot()
  expect_true(status()$synchronized)

})

test_that("we can explicitly exclude some packages from snapshot", {

  skip_on_cran()
  project <- renv_tests_scope("breakfast")
  init()

  snapshot(exclude = "oatmeal", force = TRUE)
  lockfile <- renv_lockfile_load(project)
  expect_null(lockfile$Packages$oatmeal)

})

test_that("snapshot() warns when required package is not installed", {

  renv_tests_scope("breakfast")
  init()

  remove("breakfast")
  expect_snapshot(snapshot())

  install("breakfast")
  remove("toast")
  expect_snapshot(snapshot(), error = TRUE)

})

test_that("packages installed from CRAN using pak are handled", {
  skip_on_cran()
  skip_if_not_installed("pak")
  skip_on_ci() # TODO

  renv_tests_scope()
  pak <- renv_namespace_load("pak")
  suppressMessages(pak$pkg_install("toast"))
  record <- renv_snapshot_description(package = "toast")

  expect_identical(record$Source, "Repository")
  expect_identical(record$Repository, "CRAN")
})


test_that("packages installed from Bioconductor using pak are handled", {
  skip_on_cran()
  skip_if_not_installed("pak")
  skip_on_ci() # TODO

  renv_tests_scope()
  pak <- renv_namespace_load("pak")
  suppressMessages(pak$pkg_install("bioc::Biobase"))

  record <- renv_snapshot_description(package = "Biobase")
  expect_identical(record$Source, "Bioconductor")
})

test_that("snapshot always reports on R version changes", {
  renv_scope_options(renv.verbose = TRUE)

  R4.1 <- list(R = list(Version = 4.1))
  R4.2 <- list(R = list(Version = 4.2))
  expect_snapshot({
    renv_snapshot_report_actions(list(), R4.1, R4.2)
  })
})
