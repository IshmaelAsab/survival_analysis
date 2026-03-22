workspace_lib <- normalizePath("r_libs", mustWork = FALSE)
if (dir.exists(workspace_lib)) {
  .libPaths(c(workspace_lib, .libPaths()))
}

required_pkgs <- c("survival", "flexsurv", "ggplot2", "muhaz")
missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  stop(sprintf("Missing required R packages: %s", paste(missing_pkgs, collapse = ", ")))
}

suppressPackageStartupMessages({
  library(survival)
  library(flexsurv)
  library(ggplot2)
  library(muhaz)
})

options(stringsAsFactors = FALSE)

output_dir <- "outputs"
plot_dir <- file.path(output_dir, "plots")
table_dir <- file.path(output_dir, "tables")
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

fmt_num <- function(x, digits = 3) {
  ifelse(is.na(x), "NA", formatC(x, digits = digits, format = "f"))
}

fmt_pct <- function(x, digits = 1) {
  ifelse(is.na(x), "NA", paste0(formatC(100 * x, digits = digits, format = "f"), "%"))
}

fmt_p <- function(x) {
  ifelse(is.na(x), "NA", ifelse(x < 0.001, "<0.001", formatC(x, digits = 3, format = "f")))
}

nice_var_name <- function(x) {
  tools::toTitleCase(gsub("_", " ", x, fixed = TRUE))
}

set_if_present <- function(x, lvls) {
  if (all(lvls %in% unique(x))) {
    factor(x, levels = lvls)
  } else {
    factor(x)
  }
}

survfit_to_df <- function(fit) {
  s <- summary(fit)
  strata <- if (is.null(s$strata)) {
    rep("Overall", length(s$time))
  } else {
    as.character(s$strata)
  }
  data.frame(
    time = s$time,
    surv = s$surv,
    lower = s$lower,
    upper = s$upper,
    n_risk = s$n.risk,
    n_event = s$n.event,
    strata = sub("^[^=]+=", "", strata),
    stringsAsFactors = FALSE
  )
}

extract_median_table <- function(fit, label) {
  tbl <- summary(fit)$table
  if (is.null(dim(tbl))) {
    out <- data.frame(
      analysis = label,
      strata = "Overall",
      records = unname(tbl["records"]),
      events = unname(tbl["events"]),
      median_months = unname(tbl["median"]),
      lower_95 = unname(tbl["0.95LCL"]),
      upper_95 = unname(tbl["0.95UCL"]),
      stringsAsFactors = FALSE
    )
  } else {
    out <- data.frame(
      analysis = label,
      strata = sub("^[^=]+=", "", rownames(tbl)),
      records = tbl[, "records"],
      events = tbl[, "events"],
      median_months = tbl[, "median"],
      lower_95 = tbl[, "0.95LCL"],
      upper_95 = tbl[, "0.95UCL"],
      stringsAsFactors = FALSE,
      row.names = NULL
    )
  }
  out
}

logrank_test <- function(data, variable) {
  fit <- survdiff(as.formula(sprintf("Surv(tenure_in_months, churn_event) ~ %s", variable)), data = data)
  data.frame(
    variable = variable,
    chisq = unname(fit$chisq),
    df = length(fit$n) - 1,
    p_value = 1 - pchisq(fit$chisq, df = length(fit$n) - 1),
    stringsAsFactors = FALSE
  )
}

md_table <- function(df) {
  x <- df
  headers <- paste(names(x), collapse = " | ")
  sep <- paste(rep("---", ncol(x)), collapse = " | ")
  rows <- apply(x, 1, function(r) paste(r, collapse = " | "))
  paste(
    c(
      paste0("| ", headers, " |"),
      paste0("| ", sep, " |"),
      paste0("| ", rows, " |")
    ),
    collapse = "\n"
  )
}

pick_top_rows <- function(df, n = 8) {
  if (nrow(df) == 0) {
    return(df)
  }
  df[seq_len(min(n, nrow(df))), , drop = FALSE]
}

build_term_labels <- function(design_matrix, factor_info) {
  term_names <- colnames(design_matrix)
  labels <- stats::setNames(rep(NA_character_, length(term_names)), term_names)
  for (term in term_names) {
    matched <- FALSE
    for (var in names(factor_info)) {
      if (startsWith(term, var)) {
        ref <- factor_info[[var]][1]
        level <- substring(term, nchar(var) + 1)
        labels[[term]] <- sprintf("%s: %s vs %s", nice_var_name(var), level, ref)
        matched <- TRUE
        break
      }
    }
    if (!matched) {
      labels[[term]] <- sprintf("%s (per unit)", nice_var_name(term))
    }
  }
  labels
}

pretty_ph_term <- function(term, term_labels) {
  if (!is.na(term_labels[term])) {
    return(unname(term_labels[term]))
  }
  sprintf("%s (group test)", nice_var_name(term))
}

extract_cox_results <- function(fit, term_labels) {
  s <- summary(fit)
  out <- data.frame(
    term = rownames(s$coefficients),
    estimate = s$coefficients[, "coef"],
    se = s$coefficients[, "se(coef)"],
    z = s$coefficients[, "z"],
    p_value = s$coefficients[, "Pr(>|z|)"],
    hazard_ratio = s$conf.int[, "exp(coef)"],
    conf_low = s$conf.int[, "lower .95"],
    conf_high = s$conf.int[, "upper .95"],
    stringsAsFactors = FALSE,
    row.names = NULL
  )
  out$term_label <- unname(term_labels[out$term])
  out <- out[order(out$hazard_ratio, decreasing = TRUE), ]
  rownames(out) <- NULL
  out
}

extract_survreg_results <- function(fit, model_name, term_names, term_labels) {
  coef_vec <- stats::coef(fit)
  vc <- stats::vcov(fit)
  keep <- term_names[term_names %in% names(coef_vec)]
  est <- coef_vec[keep]
  se <- sqrt(diag(vc))[keep]
  z <- est / se
  p <- 2 * stats::pnorm(abs(z), lower.tail = FALSE)
  out <- data.frame(
    model = model_name,
    term = keep,
    estimate = unname(est),
    se = unname(se),
    z = unname(z),
    p_value = unname(p),
    time_ratio = exp(unname(est)),
    conf_low = exp(unname(est - 1.96 * se)),
    conf_high = exp(unname(est + 1.96 * se)),
    stringsAsFactors = FALSE,
    row.names = NULL
  )
  out$term_label <- unname(term_labels[out$term])
  out
}

extract_flexsurv_results <- function(fit, model_name, term_names, term_labels, metric = c("time_ratio", "hazard_ratio")) {
  metric <- match.arg(metric)
  coef_vec <- stats::coef(fit)
  vc <- stats::vcov(fit)
  keep <- term_names[term_names %in% names(coef_vec)]
  est <- coef_vec[keep]
  se <- sqrt(diag(vc))[keep]
  z <- est / se
  p <- 2 * stats::pnorm(abs(z), lower.tail = FALSE)
  effect <- exp(unname(est))
  out <- data.frame(
    model = model_name,
    term = keep,
    estimate = unname(est),
    se = unname(se),
    z = unname(z),
    p_value = unname(p),
    effect = effect,
    conf_low = exp(unname(est - 1.96 * se)),
    conf_high = exp(unname(est + 1.96 * se)),
    effect_metric = metric,
    stringsAsFactors = FALSE,
    row.names = NULL
  )
  names(out)[names(out) == "effect"] <- metric
  out$term_label <- unname(term_labels[out$term])
  out
}

save_forest_plot <- function(df, estimate_col, low_col, high_col, ref_value, xlab, title, path) {
  plot_df <- df
  plot_df <- plot_df[order(plot_df[[estimate_col]]), , drop = FALSE]
  plot_df$term_label <- factor(plot_df$term_label, levels = plot_df$term_label)
  p <- ggplot(plot_df, aes(x = .data[[estimate_col]], y = term_label, color = p_value < 0.05)) +
    geom_vline(xintercept = ref_value, linetype = "dashed", color = "gray50") +
    geom_segment(aes(x = .data[[low_col]], xend = .data[[high_col]], yend = term_label), linewidth = 0.5) +
    geom_point(size = 2) +
    scale_x_log10() +
    scale_color_manual(values = c(`TRUE` = "#C23B22", `FALSE` = "#2F5D62")) +
    labs(title = title, x = xlab, y = NULL, color = "p < 0.05") +
    theme_minimal(base_size = 11) +
    theme(legend.position = "top")
  ggsave(path, plot = p, width = 9, height = max(6, 0.25 * nrow(plot_df)), dpi = 300)
}

calc_cindex <- function(time, event, score, reverse = FALSE) {
  conc <- concordance(Surv(time, event) ~ score, reverse = reverse)
  c(
    concordance = unname(conc$concordance),
    std_error = unname(sqrt(conc$var))
  )
}

predict_lp_flexsurv <- function(fit, design_matrix, term_names) {
  beta <- stats::coef(fit)
  keep <- term_names[term_names %in% names(beta)]
  as.numeric(design_matrix[, keep, drop = FALSE] %*% beta[keep])
}

raw <- read.csv("data/telecom_churn_model_covariates.csv", stringsAsFactors = FALSE, check.names = FALSE)

raw$churn_event <- ifelse(raw$churn_label == "Yes", 1L, 0L)
raw$tenure_in_months <- suppressWarnings(as.numeric(raw$tenure_in_months))

initial_n <- nrow(raw)
missing_rows <- sum(!stats::complete.cases(raw[, c("tenure_in_months", "churn_event")]))
nonpositive_rows <- sum(raw$tenure_in_months <= 0, na.rm = TRUE)

data <- subset(raw, !is.na(tenure_in_months) & tenure_in_months > 0 & !is.na(churn_event))

binary_vars <- c(
  "gender", "senior_citizen", "married", "dependents", "referred_a_friend",
  "phone_service", "multiple_lines", "internet_service", "online_security",
  "online_backup", "device_protection_plan", "premium_tech_support",
  "streaming_tv", "streaming_movies", "streaming_music", "unlimited_data",
  "paperless_billing"
)

for (v in binary_vars) {
  if (v %in% names(data)) {
    data[[v]] <- set_if_present(data[[v]], c("No", "Yes"))
  }
}

if ("gender" %in% names(data)) {
  data$gender <- set_if_present(data$gender, c("Female", "Male"))
}
if ("offer" %in% names(data)) {
  data$offer <- set_if_present(data$offer, c("None", "Offer A", "Offer B", "Offer C", "Offer D", "Offer E"))
}
if ("contract" %in% names(data)) {
  data$contract <- set_if_present(data$contract, c("Month-to-Month", "One Year", "Two Year"))
}
if ("payment_method" %in% names(data)) {
  data$payment_method <- set_if_present(data$payment_method, c("Bank Withdrawal", "Credit Card", "Mailed Check"))
}

categorical_vars <- setdiff(names(data)[vapply(data, is.factor, logical(1))], c("churn_label"))
continuous_vars <- setdiff(
  names(data)[vapply(data, is.numeric, logical(1))],
  c("tenure_in_months", "churn_event")
)

covariates <- setdiff(names(data), c("tenure_in_months", "churn_event", "churn_label"))
design_formula <- as.formula(sprintf("~ %s", paste(covariates, collapse = " + ")))
surv_formula <- as.formula(sprintf("Surv(tenure_in_months, churn_event) ~ %s", paste(covariates, collapse = " + ")))
design_matrix <- model.matrix(design_formula, data = data)
term_names <- colnames(design_matrix)[colnames(design_matrix) != "(Intercept)"]
factor_info <- lapply(data[categorical_vars], levels)
term_labels <- build_term_labels(design_matrix[, term_names, drop = FALSE], factor_info)

prep_summary <- data.frame(
  metric = c(
    "Initial rows",
    "Rows retained",
    "Rows dropped for missing survival outcome",
    "Rows dropped for nonpositive tenure",
    "Missing values in raw data",
    "Event count (churn = 1)",
    "Censored count (churn = 0)",
    "Censoring rate",
    "Continuous covariates",
    "Categorical covariates",
    "Dummy-coded design columns",
    "Standardization"
  ),
  value = c(
    initial_n,
    nrow(data),
    missing_rows,
    nonpositive_rows,
    sum(is.na(raw)),
    sum(data$churn_event == 1),
    sum(data$churn_event == 0),
    sprintf("%.4f", mean(data$churn_event == 0)),
    paste(continuous_vars, collapse = ", "),
    paste(categorical_vars, collapse = ", "),
    length(term_names),
    "Not applied to final models; raw scales were already moderate and native-unit interpretation was preferable."
  ),
  stringsAsFactors = FALSE
)
write.csv(prep_summary, file.path(table_dir, "data_preparation_summary.csv"), row.names = FALSE)

surv_obj <- Surv(data$tenure_in_months, data$churn_event)
horizons <- c(3, 6, 12, 24, 36)

km_overall <- survfit(surv_obj ~ 1, data = data)
km_contract <- survfit(surv_obj ~ contract, data = data)
km_internet <- survfit(surv_obj ~ internet_service, data = data)
km_payment <- survfit(surv_obj ~ payment_method, data = data)

km_horiz <- summary(km_overall, times = horizons, extend = TRUE)
km_horizon_df <- data.frame(
  month = km_horiz$time,
  survival_probability = km_horiz$surv,
  lower_95 = km_horiz$lower,
  upper_95 = km_horiz$upper,
  churn_probability = 1 - km_horiz$surv,
  cumulative_hazard = -log(km_horiz$surv),
  stringsAsFactors = FALSE
)
write.csv(km_horizon_df, file.path(table_dir, "km_horizon_summary.csv"), row.names = FALSE)

median_table <- rbind(
  extract_median_table(km_overall, "Overall"),
  extract_median_table(km_contract, "Contract"),
  extract_median_table(km_internet, "Internet Service"),
  extract_median_table(km_payment, "Payment Method")
)
write.csv(median_table, file.path(table_dir, "median_survival_summary.csv"), row.names = FALSE)

logrank_results <- do.call(
  rbind,
  lapply(c("contract", "internet_service", "payment_method"), function(v) logrank_test(data, v))
)
write.csv(logrank_results, file.path(table_dir, "logrank_tests.csv"), row.names = FALSE)

km_overall_df <- survfit_to_df(km_overall)
km_contract_df <- survfit_to_df(km_contract)
km_internet_df <- survfit_to_df(km_internet)
km_payment_df <- survfit_to_df(km_payment)
horizon_points <- merge(km_horizon_df, data.frame(month = horizons), by = "month", all.y = TRUE)

overall_plot <- ggplot(km_overall_df, aes(x = time, y = surv)) +
  geom_ribbon(aes(ymin = lower, ymax = upper), fill = "#BFD7EA", alpha = 0.4) +
  geom_step(color = "#0B4F6C", linewidth = 1) +
  geom_point(data = horizon_points, aes(x = month, y = survival_probability), color = "#C23B22", size = 2) +
  labs(
    title = "Overall Kaplan-Meier Survival Curve",
    x = "Tenure (months)",
    y = "Survival probability S(t)"
  ) +
  theme_minimal(base_size = 12)
ggsave(file.path(plot_dir, "km_overall.png"), plot = overall_plot, width = 8, height = 5, dpi = 300)

save_stratified_km <- function(df, title, path) {
  p <- ggplot(df, aes(x = time, y = surv, color = strata)) +
    geom_step(linewidth = 1) +
    labs(
      title = title,
      x = "Tenure (months)",
      y = "Survival probability S(t)",
      color = NULL
    ) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "top")
  ggsave(path, plot = p, width = 8.5, height = 5.5, dpi = 300)
}

save_stratified_km(km_contract_df, "Kaplan-Meier by Contract Type", file.path(plot_dir, "km_by_contract.png"))
save_stratified_km(km_internet_df, "Kaplan-Meier by Internet Service", file.path(plot_dir, "km_by_internet_service.png"))
save_stratified_km(km_payment_df, "Kaplan-Meier by Payment Method", file.path(plot_dir, "km_by_payment_method.png"))

haz_fit <- muhaz(
  times = data$tenure_in_months,
  delta = data$churn_event,
  bw.method = "global",
  min.time = min(data$tenure_in_months, na.rm = TRUE),
  max.time = max(data$tenure_in_months, na.rm = TRUE)
)
hazard_df <- data.frame(
  time = haz_fit$est.grid,
  hazard = haz_fit$haz.est,
  stringsAsFactors = FALSE
)
write.csv(hazard_df, file.path(table_dir, "smoothed_hazard_curve.csv"), row.names = FALSE)

hazard_plot <- ggplot(hazard_df, aes(x = time, y = hazard)) +
  geom_line(color = "#8B1E3F", linewidth = 1) +
  labs(
    title = "Smoothed Churn Hazard over Tenure",
    x = "Tenure (months)",
    y = "Hazard h(t)"
  ) +
  theme_minimal(base_size = 12)
ggsave(file.path(plot_dir, "smoothed_hazard.png"), plot = hazard_plot, width = 8, height = 5, dpi = 300)

peak_hazard_idx <- which.max(hazard_df$hazard)
peak_hazard_month <- hazard_df$time[peak_hazard_idx]
peak_hazard_value <- hazard_df$hazard[peak_hazard_idx]
hazard_at_horizons <- stats::approx(hazard_df$time, hazard_df$hazard, xout = horizons, rule = 2)$y

cox_fit <- coxph(surv_formula, data = data, ties = "efron", x = TRUE, model = TRUE)
cox_results <- extract_cox_results(cox_fit, term_labels)
write.csv(cox_results, file.path(table_dir, "cox_coefficients.csv"), row.names = FALSE)

cox_cindex <- calc_cindex(data$tenure_in_months, data$churn_event, predict(cox_fit, type = "lp"), reverse = TRUE)

cox_ph <- cox.zph(cox_fit, transform = "km")
cox_ph_table <- as.data.frame(cox_ph$table)
cox_ph_table$term <- rownames(cox_ph$table)
rownames(cox_ph_table) <- NULL
names(cox_ph_table) <- sub("^p$", "p_value", names(cox_ph_table))
write.csv(cox_ph_table, file.path(table_dir, "cox_ph_test.csv"), row.names = FALSE)

cox_ph_terms <- subset(cox_ph_table, term != "GLOBAL")
violations <- subset(cox_ph_terms, p_value < 0.05)
violations <- violations[order(violations$p_value), ]

selected_ph_terms <- head(violations$term, 6)
if (length(selected_ph_terms) == 0) {
  selected_ph_terms <- head(cox_ph_terms$term[order(cox_ph_terms$p_value)], 4)
}

png(file.path(plot_dir, "cox_schoenfeld_diagnostics.png"), width = 1500, height = 900, res = 150)
par(mfrow = c(2, 3), mar = c(4, 4, 3, 1))
for (term in selected_ph_terms) {
  plot(cox_ph, var = term, main = unname(term_labels[term]), resid = TRUE, se = TRUE)
  abline(h = 0, lty = 2, col = "gray50")
}
dev.off()

save_forest_plot(
  cox_results,
  estimate_col = "hazard_ratio",
  low_col = "conf_low",
  high_col = "conf_high",
  ref_value = 1,
  xlab = "Hazard ratio (log scale)",
  title = "Cox Proportional Hazards Model",
  path = file.path(plot_dir, "cox_forest_plot.png")
)

aft_survreg_specs <- c(
  Weibull = "weibull",
  LogNormal = "lognormal",
  LogLogistic = "loglogistic",
  Exponential = "exponential"
)

aft_survreg_fits <- lapply(aft_survreg_specs, function(dist_name) {
  survreg(surv_formula, data = data, dist = dist_name, model = TRUE)
})

aft_survreg_results <- do.call(
  rbind,
  Map(
    function(model_name, fit) extract_survreg_results(fit, model_name, term_names, term_labels),
    names(aft_survreg_fits),
    aft_survreg_fits
  )
)
write.csv(aft_survreg_results, file.path(table_dir, "aft_coefficients_survreg_models.csv"), row.names = FALSE)

gengamma_fit <- flexsurvreg(surv_formula, data = data, dist = "gengamma")
gengamma_results <- extract_flexsurv_results(gengamma_fit, "GeneralizedGamma", term_names, term_labels, metric = "time_ratio")
write.csv(gengamma_results, file.path(table_dir, "aft_coefficients_generalized_gamma.csv"), row.names = FALSE)

gompertz_fit <- flexsurvreg(surv_formula, data = data, dist = "gompertz")
gompertz_results <- extract_flexsurv_results(gompertz_fit, "Gompertz", term_names, term_labels, metric = "hazard_ratio")
write.csv(gompertz_results, file.path(table_dir, "gompertz_coefficients.csv"), row.names = FALSE)

aft_fit_summary <- data.frame(
  model = c(names(aft_survreg_fits), "GeneralizedGamma", "Gompertz"),
  effect_scale = c(rep("AFT time ratio", length(aft_survreg_fits) + 1), "Parametric hazard ratio"),
  aic = c(
    sapply(aft_survreg_fits, AIC),
    AIC(gengamma_fit),
    AIC(gompertz_fit)
  ),
  bic = c(
    sapply(aft_survreg_fits, BIC),
    BIC(gengamma_fit),
    BIC(gompertz_fit)
  ),
  stringsAsFactors = FALSE
)

aft_cindex_rows <- list()
for (model_name in names(aft_survreg_fits)) {
  lp <- predict(aft_survreg_fits[[model_name]], type = "lp")
  cidx <- calc_cindex(data$tenure_in_months, data$churn_event, lp, reverse = FALSE)
  aft_cindex_rows[[model_name]] <- data.frame(
    model = model_name,
    c_index = cidx["concordance"],
    c_index_se = cidx["std_error"],
    stringsAsFactors = FALSE
  )
}

gengamma_lp <- predict_lp_flexsurv(gengamma_fit, design_matrix, term_names)
gengamma_cindex <- calc_cindex(data$tenure_in_months, data$churn_event, gengamma_lp, reverse = FALSE)
aft_cindex_rows[["GeneralizedGamma"]] <- data.frame(
  model = "GeneralizedGamma",
  c_index = gengamma_cindex["concordance"],
  c_index_se = gengamma_cindex["std_error"],
  stringsAsFactors = FALSE
)

gompertz_lp <- predict_lp_flexsurv(gompertz_fit, design_matrix, term_names)
gompertz_cindex <- calc_cindex(data$tenure_in_months, data$churn_event, gompertz_lp, reverse = TRUE)
aft_cindex_rows[["Gompertz"]] <- data.frame(
  model = "Gompertz",
  c_index = gompertz_cindex["concordance"],
  c_index_se = gompertz_cindex["std_error"],
  stringsAsFactors = FALSE
)

aft_cindex_df <- do.call(rbind, aft_cindex_rows)
aft_fit_summary <- merge(aft_fit_summary, aft_cindex_df, by = "model", all.x = TRUE)
aft_fit_summary <- aft_fit_summary[order(aft_fit_summary$aic), ]
write.csv(aft_fit_summary, file.path(table_dir, "parametric_model_fit_summary.csv"), row.names = FALSE)

best_aft_model <- aft_fit_summary$model[aft_fit_summary$effect_scale == "AFT time ratio"][which.min(aft_fit_summary$aic[aft_fit_summary$effect_scale == "AFT time ratio"])]
best_aft_results <- switch(
  best_aft_model,
  Weibull = subset(aft_survreg_results, model == "Weibull"),
  LogNormal = subset(aft_survreg_results, model == "LogNormal"),
  LogLogistic = subset(aft_survreg_results, model == "LogLogistic"),
  Exponential = subset(aft_survreg_results, model == "Exponential"),
  GeneralizedGamma = gengamma_results
)

save_forest_plot(
  best_aft_results,
  estimate_col = "time_ratio",
  low_col = "conf_low",
  high_col = "conf_high",
  ref_value = 1,
  xlab = "Time ratio (log scale)",
  title = sprintf("Best AFT Model: %s", best_aft_model),
  path = file.path(plot_dir, "best_aft_forest_plot.png")
)

cox_vs_best_aft <- merge(
  cox_results[, c("term", "term_label", "estimate", "hazard_ratio", "p_value")],
  best_aft_results[, c("term", "estimate", "time_ratio", "p_value")],
  by = "term",
  suffixes = c("_cox", "_aft"),
  all = FALSE
)
cox_vs_best_aft$direction_consistent <- sign(cox_vs_best_aft$estimate_cox) == -sign(cox_vs_best_aft$estimate_aft)
write.csv(cox_vs_best_aft, file.path(table_dir, "cox_vs_best_aft_consistency.csv"), row.names = FALSE)

cox_sig <- subset(cox_results, p_value < 0.05)
cox_risk_sig <- subset(cox_sig, hazard_ratio > 1)
cox_protective_sig <- subset(cox_sig, hazard_ratio < 1)
cox_risk <- head(cox_risk_sig[order(-cox_risk_sig$hazard_ratio), c("term_label", "hazard_ratio", "conf_low", "conf_high", "p_value")], 10)
cox_protective <- head(cox_protective_sig[order(cox_protective_sig$hazard_ratio), c("term_label", "hazard_ratio", "conf_low", "conf_high", "p_value")], 10)
best_aft_sig <- subset(best_aft_results, p_value < 0.05)
aft_accel_sig <- subset(best_aft_sig, time_ratio < 1)
aft_delay_sig <- subset(best_aft_sig, time_ratio > 1)
aft_accelerators <- head(aft_accel_sig[order(aft_accel_sig$time_ratio), c("term_label", "time_ratio", "conf_low", "conf_high", "p_value")], 10)
aft_delayers <- head(aft_delay_sig[order(-aft_delay_sig$time_ratio), c("term_label", "time_ratio", "conf_low", "conf_high", "p_value")], 10)

write.csv(cox_risk, file.path(table_dir, "top_cox_risk_factors.csv"), row.names = FALSE)
write.csv(cox_protective, file.path(table_dir, "top_cox_protective_factors.csv"), row.names = FALSE)
write.csv(aft_accelerators, file.path(table_dir, "top_aft_churn_accelerators.csv"), row.names = FALSE)
write.csv(aft_delayers, file.path(table_dir, "top_aft_retention_drivers.csv"), row.names = FALSE)

overall_survival_end <- tail(km_overall_df$surv, 1)
overall_median <- median_table$median_months[median_table$analysis == "Overall"][1]
overall_median_text <- if (is.na(overall_median)) {
  sprintf("not reached within the observed 72-month window (KM survival at 72 months = %s)", fmt_pct(overall_survival_end))
} else {
  sprintf("%s months", fmt_num(overall_median, 1))
}

hazard_pattern <- if (peak_hazard_month <= 12 && hazard_at_horizons[2] > hazard_at_horizons[5]) {
  "front-loaded"
} else if (peak_hazard_month >= 24) {
  "late-tenure concentrated"
} else {
  "mid-tenure concentrated"
}

global_ph_p <- cox_ph_table$p_value[cox_ph_table$term == "GLOBAL"][1]
ph_violation_text <- if (nrow(violations) == 0) {
  "No covariate showed evidence of proportional-hazards violation at the 5% level."
} else {
  sprintf(
    "Potential proportional-hazards violations were detected for: %s.",
    paste(vapply(violations$term, pretty_ph_term, character(1), term_labels = term_labels), collapse = "; ")
  )
}

best_parametric_row <- aft_fit_summary[1, ]
cox_cindex_text <- sprintf("%s (SE %s)", fmt_num(cox_cindex["concordance"], 3), fmt_num(cox_cindex["std_error"], 3))
best_parametric_cindex_text <- sprintf("%s (SE %s)", fmt_num(best_parametric_row$c_index, 3), fmt_num(best_parametric_row$c_index_se, 3))

short_horizon_table <- data.frame(
  Month = km_horizon_df$month,
  `S(t)` = fmt_num(km_horizon_df$survival_probability, 3),
  `1 - S(t)` = fmt_num(km_horizon_df$churn_probability, 3),
  `H(t) = -log S(t)` = fmt_num(km_horizon_df$cumulative_hazard, 3),
  check.names = FALSE,
  stringsAsFactors = FALSE
)

logrank_table_md <- data.frame(
  Variable = nice_var_name(logrank_results$variable),
  ChiSquare = fmt_num(logrank_results$chisq, 2),
  DF = logrank_results$df,
  `P-value` = fmt_p(logrank_results$p_value),
  check.names = FALSE,
  stringsAsFactors = FALSE
)

fit_table_md <- data.frame(
  Model = aft_fit_summary$model,
  Scale = aft_fit_summary$effect_scale,
  AIC = fmt_num(aft_fit_summary$aic, 1),
  BIC = fmt_num(aft_fit_summary$bic, 1),
  `C-index` = fmt_num(aft_fit_summary$c_index, 3),
  check.names = FALSE,
  stringsAsFactors = FALSE
)

cox_risk_md <- transform(pick_top_rows(cox_risk, 6),
  hazard_ratio = fmt_num(hazard_ratio, 2),
  conf_low = fmt_num(conf_low, 2),
  conf_high = fmt_num(conf_high, 2),
  p_value = fmt_p(p_value)
)
names(cox_risk_md) <- c("Risk Factor", "HR", "CI Low", "CI High", "P-value")

cox_protective_md <- transform(pick_top_rows(cox_protective, 6),
  hazard_ratio = fmt_num(hazard_ratio, 2),
  conf_low = fmt_num(conf_low, 2),
  conf_high = fmt_num(conf_high, 2),
  p_value = fmt_p(p_value)
)
names(cox_protective_md) <- c("Protective Factor", "HR", "CI Low", "CI High", "P-value")

aft_delayers_md <- transform(pick_top_rows(aft_delayers, 6),
  time_ratio = fmt_num(time_ratio, 2),
  conf_low = fmt_num(conf_low, 2),
  conf_high = fmt_num(conf_high, 2),
  p_value = fmt_p(p_value)
)
names(aft_delayers_md) <- c("Retention Driver", "TR", "CI Low", "CI High", "P-value")

aft_accelerators_md <- transform(pick_top_rows(aft_accelerators, 6),
  time_ratio = fmt_num(time_ratio, 2),
  conf_low = fmt_num(conf_low, 2),
  conf_high = fmt_num(conf_high, 2),
  p_value = fmt_p(p_value)
)
names(aft_accelerators_md) <- c("Churn Accelerator", "TR", "CI Low", "CI High", "P-value")

report_lines <- c(
  "# IBM Telecom Churn Survival Analysis",
  "",
  "## Executive Summary",
  sprintf(
    "The data contain %d customers, of whom %d churned and %d were right-censored. Tenure is already strictly positive (1 to 72 months), so no observations were removed for invalid follow-up time. No missing values were present in the file. Categorical predictors were converted to factors and internally dummy-coded into %d design columns for the multivariable models.",
    nrow(data),
    sum(data$churn_event == 1),
    sum(data$churn_event == 0),
    length(term_names)
  ),
  sprintf(
    "Overall customer survival beyond churn has median survival %s. The smoothed hazard suggests a %s churn process, peaking around month %s with estimated hazard %s.",
    overall_median_text,
    hazard_pattern,
    fmt_num(peak_hazard_month, 1),
    fmt_num(peak_hazard_value, 4)
  ),
  sprintf(
    "Across parametric models, %s achieved the best AIC/BIC trade-off in this sample. The Cox model C-index was %s versus %s for the best parametric comparator (%s). These are apparent, in-sample concordance estimates and should be interpreted as optimistic.",
    best_parametric_row$model,
    cox_cindex_text,
    best_parametric_cindex_text,
    best_parametric_row$model
  ),
  "",
  "## Data Preparation",
  "Event coding used churn_label = Yes -> 1 and No -> 0. Tenure_in_months is the survival outcome time scale, not a feature. Because the numeric covariates were already on moderate scales and the models converged stably, I kept them in native units for interpretability rather than z-scoring them. Structural zeros, such as zero GB download for customers without internet service, were retained as observed values rather than treated as missing.",
  "",
  "## Exploratory Survival Analysis",
  "### Kaplan-Meier Survival at Business Horizons",
  md_table(short_horizon_table),
  "",
  "### Log-Rank Tests",
  md_table(logrank_table_md),
  "",
  "The log-rank tests indicate whether survival curves differ across customer segments. In business terms, they test whether churn timing differs materially by contract, internet service status, and payment method.",
  "",
  "## Cox Proportional Hazards Model",
  "The multivariable Cox model estimates",
  "",
  "h(t | X) = h0(t) exp(beta'X),",
  "",
  "where h0(t) is the baseline hazard over tenure and the covariates shift that hazard proportionally. Time therefore enters through the evolving baseline hazard, while the coefficients summarize relative instantaneous churn risk at each tenure point.",
  "",
  "### Largest Hazard-Increasing Effects",
  md_table(cox_risk_md),
  "",
  "### Largest Protective Effects",
  md_table(cox_protective_md),
  "",
  sprintf(
    "Global Schoenfeld residual test p-value: %s. %s",
    fmt_p(global_ph_p),
    ph_violation_text
  ),
  "",
  "## Parametric Survival Models",
  "For AFT models the main interpretation is",
  "",
  "log(T) = beta'X + sigma * epsilon,",
  "",
  "so exp(beta_j) is a time ratio. TR > 1 means longer time to churn, while TR < 1 means faster churn. The Gompertz model is included as a parametric comparator, but its covariates act on the hazard-rate parameter, so its coefficients are naturally read as hazard ratios rather than constant time ratios.",
  "",
  "### Model Fit Comparison",
  md_table(fit_table_md),
  "",
  sprintf("The best AFT specification by AIC was %s.", best_aft_model),
  "",
  "### Strongest Time-Extending Effects in the Best AFT Model",
  md_table(aft_delayers_md),
  "",
  "### Strongest Time-Shortening Effects in the Best AFT Model",
  md_table(aft_accelerators_md),
  "",
  "## How Survival Analysis Uses Time in Predicting Churn",
  "Survival analysis models the full time-to-churn variable T rather than collapsing churn into a single yes/no label. The survival function S(t) = P(T > t) tells us the probability a customer is still retained after tenure t. The hazard h(t) is the instantaneous churn intensity at tenure t among customers who have not yet churned. The cumulative hazard H(t) = integral_0^t h(u) du = -log(S(t)) tracks the accumulated churn pressure over time.",
  "",
  "This is fundamentally different from a standard churn classifier such as logistic regression or a tree ensemble. A classifier treats a customer who churns in month 2 the same as a customer who churns in month 35, even though their retention dynamics are very different. It also throws away censoring information: a customer observed for 60 months without churn contains much more retention information than a customer observed for only 3 months, but a binary classifier typically cannot use that exposure difference directly.",
  "",
  sprintf(
    "In this dataset, the tenure pattern is %s: hazard peaks around month %s and then changes over the customer lifecycle. That means retention actions are not equally valuable at every point in tenure. Survival analysis reveals both who is risky and when that risk is concentrated.",
    hazard_pattern,
    fmt_num(peak_hazard_month, 1)
  ),
  "",
  "For the Cox model, proportional hazards means a covariate's multiplicative effect on churn risk is assumed constant over tenure. When Schoenfeld diagnostics reject that assumption, the substantive interpretation is that some drivers matter more early than late in the customer lifecycle. Remedies include stratifying on the offending factor, adding time-varying effects such as X * f(t), or switching to more flexible parametric or spline-based models.",
  "",
  "For AFT models, coefficients directly stretch or compress time to churn. That makes them especially intuitive for retention planning: they estimate how customer characteristics delay churn or accelerate it. Hazard ratios from Cox answer who faces higher instantaneous churn pressure; time ratios from AFT answer how much longer or shorter customers are likely to remain before churning.",
  "",
  "## Business Implications",
  "The early-tenure hazard pattern implies that onboarding and first-year engagement are the highest-value intervention window. Survival probabilities at 3, 6, 12, 24, and 36 months can be used as proactive service-level targets rather than waiting for a binary churn flag.",
  "The strongest hazard-increasing factors highlight high-risk segments that should receive earlier retention outreach, pricing review, or service-resolution support. The strongest protective factors indicate which features, offers, or relationship characteristics are associated with longer customer lifetime.",
  "Compared with a static classifier, the survival framework supports timing-sensitive actions: prioritize intervention before the hazard peak, refresh contract or offer strategies before known high-risk tenure windows, and differentiate early-lifecycle rescue tactics from long-tenure loyalty tactics.",
  "",
  "## Caveats",
  "These results are associational, not causal. Covariate effects may reflect selection, pricing strategy, product bundles, or omitted operational factors. The analysis uses right-censored observational data and apparent in-sample model fit; production deployment would benefit from out-of-sample validation and recalibration."
)

writeLines(report_lines, file.path(output_dir, "telecom_churn_survival_report.md"))

session_summary <- data.frame(
  item = c(
    "Peak hazard month",
    "Peak hazard value",
    "Overall median survival",
    "Cox C-index",
    "Best parametric model",
    "Best parametric AIC",
    "Best parametric C-index",
    "Global PH p-value"
  ),
  value = c(
    peak_hazard_month,
    peak_hazard_value,
    ifelse(is.na(overall_median), NA, overall_median),
    cox_cindex["concordance"],
    best_parametric_row$model,
    best_parametric_row$aic,
    best_parametric_row$c_index,
    global_ph_p
  ),
  stringsAsFactors = FALSE
)
write.csv(session_summary, file.path(table_dir, "analysis_session_summary.csv"), row.names = FALSE)

cat("Survival analysis completed.\n")
