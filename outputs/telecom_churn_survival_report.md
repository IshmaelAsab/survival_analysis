# IBM Telecom Churn Survival Analysis

## Executive Summary

The data contain 7043 customers, of whom 1869 churned and 5174 were right-censored. Tenure is already strictly positive (1 to 72 months), so no observations were removed for invalid follow-up time. 

No missing values were present in the file. Categorical predictors were converted to factors and internally dummy-coded into 32 design columns for the multivariable models.

Overall customer survival beyond churn has median survival not reached within the observed 72-month window (KM survival at 72 months = 59.3%). The smoothed hazard suggests a front-loaded churn process, peaking around month 1.0 with estimated hazard 0.8352.

Across parametric models, Gompertz achieved the best AIC/BIC trade-off in this sample. The Cox model C-index was 0.943 (SE 0.002) versus 0.943 (SE 0.002) for the best parametric comparator (Gompertz). These are apparent, in-sample concordance estimates and should be interpreted as optimistic.


## Data Preparation

Event coding used churn_label = Yes -> 1 and No -> 0. 

Tenure_in_months is the survival outcome time scale, not a feature. 
Because the numeric covariates were already on moderate scales and the models converged stably, I kept them in native units for interpretability rather than z-scoring them. 
Structural zeros, such as zero GB download for customers without internet service, were retained as observed values rather than treated as missing.

## Exploratory Survival Analysis

### Kaplan-Meier Survival at Business Horizons
| Month | S(t) | 1 - S(t) | H(t) = -log S(t) |
| --- | --- | --- | --- |
|  3 | 0.914 | 0.086 | 0.090 |
|  6 | 0.885 | 0.115 | 0.122 |
| 12 | 0.843 | 0.157 | 0.170 |
| 24 | 0.789 | 0.211 | 0.237 |
| 36 | 0.749 | 0.251 | 0.289 |

### Log-Rank Tests

| Variable | ChiSquare | DF | P-value |
| --- | --- | --- | --- |
| Contract | 2768.99 | 2 | <0.001 |
| Internet Service | 251.96 | 1 | <0.001 |
| Payment Method | 328.39 | 2 | <0.001 |

The log-rank tests indicate whether survival curves differ across customer segments. In business terms, they test whether churn timing differs materially by contract, internet service status, and payment method.

## Cox Proportional Hazards Model

The multivariable Cox model estimates

h(t | X) = h0(t) exp(beta'X),

where h0(t) is the baseline hazard over tenure and the covariates shift that hazard proportionally. Time therefore enters through the evolving baseline hazard, while the coefficients summarize relative instantaneous churn risk at each tenure point.

### Largest Hazard-Increasing Effects

| Risk Factor | HR | CI Low | CI High | P-value |
| --- | --- | --- | --- | --- |
| Offer: Offer E vs None | 4.60 | 3.98 | 5.31 | <0.001 |
| Internet Service: Yes vs No | 1.62 | 1.24 | 2.12 | <0.001 |
| Payment Method: Mailed Check vs Bank Withdrawal | 1.46 | 1.22 | 1.75 | <0.001 |
| Phone Service: Yes vs No | 1.45 | 1.20 | 1.75 | <0.001 |

### Largest Protective Effects

| Protective Factor | HR | CI Low | CI High | P-value |
| --- | --- | --- | --- | --- |
| Contract: Two Year vs Month-to-Month | 0.07 | 0.05 | 0.09 | <0.001 |
| Contract: One Year vs Month-to-Month | 0.32 | 0.27 | 0.39 | <0.001 |
| Offer: Offer A vs None | 0.36 | 0.25 | 0.52 | <0.001 |
| Satisfaction Score (per unit) | 0.40 | 0.38 | 0.42 | <0.001 |
| Dependents: Yes vs No | 0.45 | 0.29 | 0.70 | <0.001 |
| Offer: Offer B vs None | 0.45 | 0.36 | 0.55 | <0.001 |

Global Schoenfeld residual test p-value: <0.001. Potential proportional-hazards violations were detected for: Offer (group test); Satisfaction Score (per unit); Contract (group test); Streaming Movies (group test); Device Protection Plan (group test); Internet Service (group test); Premium Tech Support (group test); Streaming Tv (group test); Online Security (group test); Multiple Lines (group test); Number of Dependents (per unit); Dependents (group test); Streaming Music (group test); Online Backup (group test); Married (group test); Referred a Friend (group test); Avg Monthly Gb Download (per unit).

## Parametric Survival Models

For AFT models the main interpretation is

log(T) = beta'X + sigma * epsilon,

so exp(beta_j) is a time ratio. TR > 1 means longer time to churn, while TR < 1 means faster churn. The Gompertz model is included as a parametric comparator, but its covariates act on the hazard-rate parameter, so its coefficients are naturally read as hazard ratios rather than constant time ratios.

### Model Fit Comparison

| Model | Scale | AIC | BIC | C-index |
| --- | --- | --- | --- | --- |
| Gompertz | Parametric hazard ratio | 14459.2 | 14692.4 | 0.943 |
| GeneralizedGamma | AFT time ratio | 14558.8 | 14798.9 | 0.945 |
| LogNormal | AFT time ratio | 14590.4 | 14823.7 | 0.945 |
| LogLogistic | AFT time ratio | 14638.6 | 14871.8 | 0.945 |
| Weibull | AFT time ratio | 14679.1 | 14912.4 | 0.943 |
| Exponential | AFT time ratio | 14794.8 | 15021.2 | 0.943 |

The best AFT specification by AIC was GeneralizedGamma.

### Strongest Time-Extending Effects in the Best AFT Model

| Retention Driver | TR | CI Low | CI High | P-value |
| --- | --- | --- | --- | --- |
| Contract: Two Year vs Month-to-Month | 5.17 | 4.14 | 6.46 | <0.001 |
| Contract: One Year vs Month-to-Month | 2.41 | 2.08 | 2.79 | <0.001 |
| Offer: Offer B vs None | 2.21 | 1.85 | 2.65 | <0.001 |
| Online Security: Yes vs No | 2.21 | 1.96 | 2.49 | <0.001 |
| Satisfaction Score (per unit) | 2.17 | 2.07 | 2.28 | <0.001 |
| Dependents: Yes vs No | 1.98 | 1.41 | 2.78 | <0.001 |

### Strongest Time-Shortening Effects in the Best AFT Model

| Churn Accelerator | TR | CI Low | CI High | P-value |
| --- | --- | --- | --- | --- |
| Offer: Offer E vs None | 0.28 | 0.25 | 0.31 | <0.001 |
| Payment Method: Mailed Check vs Bank Withdrawal | 0.65 | 0.55 | 0.77 | <0.001 |
| Internet Service: Yes vs No | 0.65 | 0.52 | 0.81 | <0.001 |
| Phone Service: Yes vs No | 0.75 | 0.63 | 0.88 | <0.001 |
| Streaming Music: Yes vs No | 0.82 | 0.70 | 0.96 | 0.015 |
| Number of Dependents (per unit) | 0.86 | 0.75 | 0.99 | 0.041 |

## How Survival Analysis Uses Time in Predicting Churn

Survival analysis models the full time-to-churn variable T rather than collapsing churn into a single yes/no label. The survival function S(t) = P(T > t) tells us the probability a customer is still retained after tenure t. The hazard h(t) is the instantaneous churn intensity at tenure t among customers who have not yet churned. The cumulative hazard H(t) = integral_0^t h(u) du = -log(S(t)) tracks the accumulated churn pressure over time.

This is fundamentally different from a standard churn classifier such as logistic regression or a tree ensemble. A classifier treats a customer who churns in month 2 the same as a customer who churns in month 35, even though their retention dynamics are very different. It also throws away censoring information: a customer observed for 60 months without churn contains much more retention information than a customer observed for only 3 months, but a binary classifier typically cannot use that exposure difference directly.

In this dataset, the tenure pattern is front-loaded: hazard peaks around month 1.0 and then changes over the customer lifecycle. That means retention actions are not equally valuable at every point in tenure. Survival analysis reveals both who is risky and when that risk is concentrated.

For the Cox model, proportional hazards means a covariate's multiplicative effect on churn risk is assumed constant over tenure. When Schoenfeld diagnostics reject that assumption, the substantive interpretation is that some drivers matter more early than late in the customer lifecycle. Remedies include stratifying on the offending factor, adding time-varying effects such as X * f(t), or switching to more flexible parametric or spline-based models.

For AFT models, coefficients directly stretch or compress time to churn. That makes them especially intuitive for retention planning: they estimate how customer characteristics delay churn or accelerate it. Hazard ratios from Cox answer who faces higher instantaneous churn pressure; time ratios from AFT answer how much longer or shorter customers are likely to remain before churning.

## Business Implications

The early-tenure hazard pattern implies that onboarding and first-year engagement are the highest-value intervention window. Survival probabilities at 3, 6, 12, 24, and 36 months can be used as proactive service-level targets rather than waiting for a binary churn flag.
The strongest hazard-increasing factors highlight high-risk segments that should receive earlier retention outreach, pricing review, or service-resolution support. The strongest protective factors indicate which features, offers, or relationship characteristics are associated with longer customer lifetime.
Compared with a static classifier, the survival framework supports timing-sensitive actions: prioritize intervention before the hazard peak, refresh contract or offer strategies before known high-risk tenure windows, and differentiate early-lifecycle rescue tactics from long-tenure loyalty tactics.

## Caveats

These results are associational, not causal. Covariate effects may reflect selection, pricing strategy, product bundles, or omitted operational factors. The analysis uses right-censored observational data and apparent in-sample model fit; production deployment would benefit from out-of-sample validation and recalibration.
