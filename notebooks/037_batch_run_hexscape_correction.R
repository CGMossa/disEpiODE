#+ setup
library(magrittr)
library(tidyverse)
# library(sf)
#
library(glue)
library(disEpiODE)

# NOTE: Make sure to install disEpiODE before running this script

# Clean the `output` directory, if it is there.
# disEpiODE:::clear_output_dir()
options(error = recover)

#'
#'
tag <- "037" # REMEMBER TO SET THIS
world_scale <- 29
params1 <- tidyr::expand_grid(
  world_scale = world_scale,
  # beta_baseline = 0.05,
  # beta_baseline = c(0.05),
  # beta_baseline = c(0.1, 0.05, 0.005, 0.01),
  beta_baseline = c(0.05),
  buffer_offset_percent = 0.2,
  buffer_radius = 3.5,
  cellarea = seq_cellarea(precision = 0.1, min_cellarea = 3, max_cellarea = world_scale),
  # celltype = c("square", "hexagon", "hexagon_rot", "triangle"),
  # celltype = commandArgs(TRUE),
  # celltype = "square",
  celltype = c("triangle"),

  # offset = "corner",
  # offset = c("corner", "middle", "bottom", "left"), #TODO
) %>%
  # dplyr::sample_n(size = dplyr::n()) %>%
  identity()

library(future)
plan(multisession(workers = 6))
# plan(multicore(workers = 6))
# plan(future::sequential())
library(furrr)

output_summary <-
  furrr::future_map(
    .options = furrr_options(),

    # purrr::map(
    purrr::transpose(params1),
    \(params) {
      params_spec <- {
        params_min <- params
        params_min$tag <- NULL
        paste0(names(params_min), "_", params_min, collapse = "_")
      }
      # FIXME: remove this within the script..
      # params$root <- fs::path_expand(".")
      tag <- tag
      rmarkdown::render(
        input = glue("notebooks/036_run_hexscape_correction.R"),
        output_file =
          glue::glue("{tag}_{params_spec}_.html"),
        output_dir = "output/",
        params = params,
        intermediates_dir = tempdir(),
        clean = TRUE,
        quiet = FALSE
      )
      report_row
    }
  )
#'
#'
output_summary %>%
  bind_rows() %>%
  arrange(cellarea) %>%
  # print(n = Inf, width = Inf) %>%
  readr::write_excel_csv(glue("output/{tag}_output_summary.csv"))

beepr::beep()
