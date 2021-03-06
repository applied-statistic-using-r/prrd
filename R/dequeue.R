##' Dequeue package for (potentially parallel) reverse-dependency check
##'
##' This function consumes previously enqueued jobs for reverse dependency checks.
##' It is set up in such a way that multiple distinct and independent process can
##' run checks in parallel without effecting each other. If the underlying queue
##' file is on a network drive, this should may also work across multiple machines.
##' @title Dequeue and run reverse-dependency checks, possibly in parallel
##' @param package A character variable denoting a package
##' @param directory A character variable denoting a directory
##' @param exclude An optional character variable denoting an exclusion set csv file.
##' @return A queue is create as a side effect, its elements are returned invisibly
##' @author Dirk Eddelbuettel
dequeueJobs <- function(package, directory, exclude="") {

    runSanityChecks()                       # (currently) checks (only) for xvfb-run-safe

    ## setting repos now in local/setup.R

    db <- getQueueFile(package=package, path=directory)
    q <- ensure_queue("jobs", db = db)

    con <- getDatabaseConnection(db)        # we re-use the liteq db for our results
    createTable(con)

    pid <- Sys.getpid()
    hostname <- Sys.info()[["nodename"]]
    wd <- cwd <- getwd()
    debug <- verbose <- FALSE

    if (!is.null(cfg <- getConfig())) {
        if ("setup" %in% names(cfg)) source(cfg$setup)
        if ("workdir" %in% names(cfg)) wd <- cfg$workdir
        if ("libdir" %in% names(cfg)) Sys.setenv("R_LIBS_USER"=cfg$libdir)
        if ("verbose" %in% names(cfg)) verbose <- cfg$verbose == "true"
        if ("debug" %in% names(cfg)) debug <- cfg$debug == "true"
    }

    good <- bad <- skipped <- 0
    exclset <- if (exclude != "") getExclusionSet(exclude) else character()
    if (verbose) print(exclset)

    ## work down messages, if any
    while (!is.null(msg <- try_consume(q))) {
        starttime <- Sys.time()
        if (debug) print(msg)

        cat(msg$message, "started at", format(starttime), "")

        tok <- strsplit(msg$message, "_")[[1]]      # now have package and version in tok[1:2]
        pkgfile <- paste0(msg$message, ".tar.gz")

        if (tok[1] %in% exclset) {
            rc <- 2

        } else {

            ## deal with exclusion set here or in enqueue ?
            setwd(wd)

            if (file.exists(pkgfile)) {
                if (verbose) cat("Seeing file", pkgfile, "\n")
            } else {
                ##download.file(pathpkg, pkg, quiet=TRUE)
                dl <- download.packages(tok[1], ".", method="wget", quiet=TRUE)
                pkgfile <- basename(dl[,2])
                if (verbose) cat("Downloaded ", pkgfile, "\n")
            }

            cmd <- paste("xvfb-run-safe --server-args=\"-screen 0 1024x768x24\" ",
                         "R",  #rbinary,         # R or RD
                         " CMD check --no-manual --no-vignettes ", pkgfile, " 2>&1 > ",
                         pkgfile, ".log", sep="")
            if (debug) print(cmd)
            rc <- system(cmd)
            if (debug) print(rc)

            setwd(cwd)
        }
        endtime <- Sys.time()

        if (rc == 0) {
            good <- good + 1
            cat(green("success"))
            ack(msg)
        } else if (rc == 2) {
            skipped <- skipped + 1
            cat(blue("skipped"))
            ack(msg)
        } else {
            bad <- bad + 1
            cat(red("failure"))
            ack(msg)
        }
        cat("", "at", format(endtime),
            paste0("(",green(good), "/", blue(skipped), "/", red(bad), ")"),
            "\n")

        row <- data.frame(package=tok[1],
                          version=tok[2],
                          result=rc,
                          starttime=format(starttime),
                          endtime=format(endtime),
                          runtime=as.numeric(difftime(endtime, starttime, units="secs")),
                          runner=pid,
                          host=hostname)
        if (debug) print(row)

        insertRow(con, row)
    }
    requeue_failed_messages(q)
    lst <- list_messages(q)
    if (verbose) print(lst)
    dbDisconnect(con)
    lst
}
