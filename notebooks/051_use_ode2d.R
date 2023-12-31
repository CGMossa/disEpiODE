
# NOTE: Make sure to install disEpiODE before running this script

# Clean the `output` directory, if it is there.
# disEpiODE:::clear_output_dir()
# options(error = recover)
# devtools::load_all()
library(disEpiODE)

library(future)
plan(multisession(workers = 4))
library(furrr)


tag <- "043" # REMEMBER TO SET THIS
world_scale <- 29
params1 <- tidyr::expand_grid(
  world_scale = world_scale,
  beta_baseline = c(0.05),
  buffer_offset_percent = 0.2,
  buffer_radius = 3.5,
  cellarea = c(
    0.25, # 29** 2 / 0.20 = 4205
    # seq_cellarea(n = 50, min_cellarea = 0.45, max_cellarea = world_scale)
    seq_cellarea(n = 75, min_cellarea = 0.45, max_cellarea = world_scale)
  ),
  # celltype = c("square", "hexagon", "hexagon_rot", "triangle"),
  celltype = c("square", "hexagon", "triangle"),
  # offset = "corner",
  # offset = c("corner", "middle", "bottom", "left"), #TODO
  # hmax = c(NA, 0.3, 0.3 / 2, 0.3 / 2 / 2),
  # hmax = c(NA, 0.25)
  hmax = c(0.25)
) %>%
  # dplyr::sample_n(size = dplyr::n()) %>%
  identity()

# pmap(params1,
future_pmap(params1, .progress = TRUE,
            \(world_scale, beta_baseline, buffer_offset_percent, buffer_radius, cellarea, celltype, hmax) {

              source_target <-
                get_buffer_source_target(landscape_width = world_scale,
                                         landscape_height = world_scale,
                                         buffer_radius = buffer_radius,
                                         buffer_offset_percent = buffer_offset_percent)
              middle_buffer <- get_middle_buffer(source_target = source_target,
                                                 buffer_radius = buffer_radius)

              world <- create_landscape(scale = world_scale)
              world_landscape <- world$landscape

              all_buffers <-
                rbind(source_target, middle_buffer) %>%
                mutate(label = factor(label, c("source", "middle", "target")))
              world_area <- st_area(world_landscape)

              grid <- create_grid(landscape = world_landscape,
                                  cellarea = cellarea,
                                  celltype = celltype)

              grid <- grid %>% rowid_to_column("id")
              population_total <- world_area
              grid$carry <- st_area(grid$geometry)

              y_init <- c(S = grid$carry,
                          I = numeric(length(grid$carry)))

              all_buffers_overlap <-
                all_buffers %>%
                rowwise() %>%
                dplyr::group_map(
                  \(buffer, ...) {
                    create_buffer_overlap(grid, buffer)
                  }
                )
              all_buffers_overlap_map <-
                all_buffers_overlap %>%
                map(. %>% create_buffer_overlap_map()) %>%
                flatten()

              source_overlap <- all_buffers_overlap_map$source
              target_overlap <- all_buffers_overlap_map$target
              middle_overlap <- all_buffers_overlap_map$middle

              half_infected_mass <-
                grid$carry[source_overlap$id_overlap] *
                source_overlap$weight *
                (1/2)
              #' remove mass from susceptible
              y_init[source_overlap$id_overlap] <-
                y_init[source_overlap$id_overlap] - half_infected_mass
              y_init[
                nrow(grid) +
                  source_overlap$id_overlap
              ] <- +half_infected_mass

              dist_grid <- st_distance(st_centroid(grid$geometry))
              # VALIDATION
              # isSymmetric(dist_grid)

              # kernel(d) = 1 / (1 + d)
              beta_mat_inverse <- beta_baseline * (1/(1 + dist_grid))
              stopifnot(all(is.finite(beta_mat_inverse)))
              diag(beta_mat_inverse) %>% unique() %>% {
                stopifnot(isTRUE(all.equal(., beta_baseline)))
              }


              # kernel(d) = exp(-d)

              beta_mat_exp <- beta_baseline * exp(-dist_grid)

              stopifnot(all(is.finite(beta_mat_exp)))
              diag(beta_mat_exp) %>% unique() %>% {
                stopifnot(isTRUE(all.equal(., beta_baseline)))
              }

              # kernel(d) = 2×pdf(mean = 0, sd = mean_formula(1))

              # dist_grid_half_normal <- dist_grid
              # diag(dist_grid_half_normal) <- 0
              beta_mat_half_normal <- beta_baseline *
                half_normal_kernel(dist_grid) / half_normal_kernel(0)
              # beta_mat_half_normal <- beta_baseline *
              #   half_normal_param_kernel(dist_grid, 1.312475, -1.560466, 3.233037)
              # diag(beta_mat_half_normal) <- beta_baseline

              # this test fails, but
              # > half_normal_param_kernel(0, 1.312475, -1.560466, 3.233037)
              # [1] 0.9999617
              # and it should exactly 1
              #
              # diag(beta_mat_half_normal) %>% unique() %>% {
              #   stopifnot(isTRUE(all.equal(., beta_baseline)))
              # }
              stopifnot(all(is.finite(beta_mat_half_normal)))


              # create_si_model(grid, beta_mat, y_init,
              #                 target_overlap, middle_overlap) ->
              #   model_output
              #
              n_grid <- nrow(grid)
              parameter_list <- list(
                N = n_grid,
                carry = grid$carry,
                area = grid$area,
                target_overlap = target_overlap,
                middle_overlap = middle_overlap
              )

              # common parameters
              ode_parameters <- list(
                # method = "euler",

                verbose = FALSE,
                y = y_init,
                func = disEpiODE:::model_func,
                ynames = FALSE,
                nspec = 2L,
                dimens = c(n_grid, n_grid) %>% sqrt()
              )
              tau_model_output_exp <-
                rlang::exec(deSolve::ode.2D,
                            !!!ode_parameters,
                            parms = parameter_list %>% append(list(
                              beta_mat = beta_mat_exp
                            )),
                            hmax = if (is.na(hmax)) { NULL } else { hmax },
                            rootfunc = disEpiODE:::find_target_prevalence,
                            times = c(0, Inf))
              rstate_exp <- deSolve::diagnostics(tau_model_output_exp)$rstate
              tau_exp <- tau_model_output_exp[2, 1]
              tau_model_output_half_normal <-
                rlang::exec(deSolve::ode.2D,
                            !!!ode_parameters,
                            parms = parameter_list %>% append(list(
                              beta_mat = beta_mat_half_normal
                            )),
                            hmax = if (is.na(hmax)) { NULL } else { hmax },
                            rootfunc = disEpiODE:::find_target_prevalence,
                            times = c(0, Inf))
              rstate_half_normal <- deSolve::diagnostics(tau_model_output_half_normal)$rstate
              tau_half_normal <- tau_model_output_half_normal[2, 1]
              #TODO: Note that `hmax` is separate here for the other two
              tau_model_output_inverse <-
                rlang::exec(deSolve::ode.2D,
                            !!!ode_parameters,
                            hmax = 0.040,
                            parms = parameter_list %>% append(list(
                              beta_mat = beta_mat_inverse
                            )),
                            rootfunc = disEpiODE:::find_target_prevalence,
                            times = c(0, Inf))
              rstate_inverse <- deSolve::diagnostics(tau_model_output_inverse)$rstate
              #TODO: check if tau exists
              tau_inverse <- tau_model_output_inverse[2, 1]
              list(
                output_inverse = list(
                  tau = tau_inverse,
                  rstate = rstate_inverse
                ),
                output_exp = list(
                  tau = tau_exp,
                  rstate = rstate_exp
                ),
                output_half_normal = list(
                  tau = tau_half_normal,
                  rstate = rstate_half_normal
                )
              )
            }) ->
  #TODO: rename this
  tau_rstate

model_output_df <-
  params1 %>%
  bind_cols(
    tau_rstate %>% enframe("id", "output")
  ) %>%
  unnest_longer(output) %>%
  mutate(beta_mat = output_id %>%
           str_remove("output_")) %>%
  unnest_wider(output) %>%
  #' just pick out the first `rstate`
  mutate(hlast = rstate %>% map_dbl(`[`(1))) %>%
  unnest_wider(rstate, names_sep = "_") %>%
  # mutate(`hWhat?` = rstate %>% map_dbl(`[`(2))) %>%
  # glimpse() %>%
  # print(width = Inf) %>%
  identity()


model_output_df %>%
  glimpse()


hmax_legend <- paste(Delta, " ", t[max]) %>% expression()

model_output_df %>%
  # filter(
  #   cellarea
  #   celltype
  #   hmax
  # )
  mutate(hmax_label = replace_na(as.character(hmax), "auto")) %>%
  group_by(beta_mat) %>%
  group_map(\(data, group_id) {
    ggplot(data) +
      aes(cellarea, tau, group = str_c(celltype, hmax)) +
      # geom_step(aes(linetype = hmax)) +
      geom_step(aes(color = celltype)) +
      scale_x_log10_rev() +
      theme_reverse_arrow_x() +
      theme(legend.position = "bottom") +
      facet_wrap(~hmax_label, labeller = label_both) +
      labs(linetype = hmax_legend,
           caption = glue("beta_mat: {group_id}")) +
      theme_blank_background()
  }
  )

model_output_df %>%
  mutate(hmax_label = replace_na(as.character(hmax), "auto")) %>%
  glimpse() %>%
  group_by(beta_mat) %>%
  group_map(\(data, group_id) {
    ggplot(data) +
      aes(cellarea, group = str_c(celltype, hmax)) +
      aes(y=rstate_1) +
      geom_step(aes(color = factor(hmax))) +
      # scale_x_log10_rev() +
      # expand_limits(y = 0) +
      labs(linetype = hmax_legend,
           caption = glue("beta_mat: {group_id}")) +
      # theme_reverse_arrow_x() +
      theme_blank_background()
  })

# NEEDS TO BE ADJUSTED
#' p_rstate_base <- tau_df %>%
#'   ggplot() +
#'   aes(cellarea, group = str_c(celltype, hmax)) +
#'   geom_step(aes(color = factor(hmax))) +
#'   # scale_x_log10_rev() +
#'   # expand_limits(y = 0) +
#'   labs(color = expression(paste(Delta, " ", t[max]))) +
#'   # theme_reverse_arrow_x() +
#'   theme_blank_background()
#' #'
#' #'
#' #' Auxillary plots: Are there more information in`rstate`?
#' p_rstate_base +
#'   aes(y = rstate_1)
#' p_rstate_base +
#'   aes(y = rstate_2)
#' p_rstate_base +
#'   aes(y = rstate_3)
#' p_rstate_base +
#'   aes(y = rstate_4)
#' p_rstate_base +
#'   aes(y = rstate_5)

