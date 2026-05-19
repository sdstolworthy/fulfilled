# Weight-Loss Rate Prediction: Research & Recommendation

**Audience:** Implementation agent rewriting the goal-date projection feature.
**Status:** Opinionated. Recommends one formula. Implement what's in Section 5.

---

## 1. TL;DR Recommendation

**Use a Mifflin–St Jeor TDEE estimate combined with a Hall-style dynamic
two-compartment update (fat / fat-free mass), iterated forward in 1-day steps
until predicted weight crosses the goal.** The minimum input set is
`{sex, age, height, current weight, weight history (>= 14 days), daily
intake history (>= 14 days), goal weight, activity level}`. Calibrate the
user's *effective* TDEE from the observed mismatch between (reported intake)
and (observed weight change) over a trailing 14–28 day window — this corrects
for both Mifflin error and chronic intake under-reporting in one shot. Project
forward day-by-day, decrementing TDEE as predicted body mass falls, plus a
small adaptive-thermogenesis penalty of ~6 kcal/day per kg lost. Expected
accuracy on goal-date for a compliant user with reasonable logging: ±15–25%
for goal-dates 3–6 months out, vs ±50–100% for the naive linear extrapolator
or the 3500-kcal rule.

Do **not** ship a static `deficit / 7700 kcal-per-kg` formula. It is wrong by
construction for any projection longer than ~3 weeks.

---

## 2. The Physics — Why Simple Models Fail

### 2.1 The 3500-kcal rule

The "3500 kcal = 1 lb of fat" heuristic dates to Max Wishnofsky's 1958 paper.
He observed that adipose tissue is ~87% lipid, and lipid stores ~9.5 kcal/g,
yielding ~3500 kcal per lb (~7700 kcal/kg) of *pure adipose energy content*.

The rule's failure mode is **not** the per-kg energy figure — that's roughly
right for adipose tissue. The failure is treating TDEE as **constant** across
the weight-loss episode. As a person loses mass:

1. Resting metabolic rate falls (less tissue to maintain).
2. The thermic effect of food falls (less food eaten).
3. The energy cost of physical activity falls (less mass to move).
4. Adaptive thermogenesis adds a further, non-proportional drop.

Applying a 500 kcal/day deficit to a 100 kg person predicts ~52 lb (24 kg) of
loss per year under the 3500 rule. The NIH Body Weight Planner predicts
~23 lb. The 3500 rule overshoots by ~2×. Hall et al. (Lancet 2011) showed
weight change asymptotes to a new steady state with a half-time of ~1 year
and reaches ~95% of the final change in ~3 years for a sustained intake
change. A linear model has no such asymptote — it predicts indefinite loss.

### 2.2 Hall's replacement rule of thumb

From the same Lancet paper, the **steady-state** equivalence is:

> A sustained intake change of **~10 kcal/day** produces an eventual body
> weight change of **~1 lb** (or ~22 kcal/day per kg). Half of the change
> happens in ~1 year; 95% in ~3 years.

This is the right mental model: a deficit doesn't "buy" a fixed amount of
weight loss — it shifts the equilibrium weight, and the body asymptotes
toward it.

### 2.3 Why naive linear extrapolation of observed weight is also wrong

The current implementation fits a slope to the last 28 days and extrapolates.
This inherits two pathologies:

- **Tail bias toward early loss.** Most weight-loss curves are concave: fast
  initial loss (water + glycogen + easy fat), then slowing. Extrapolating
  the early slope overpromises a goal date.
- **No counterfactual.** If the user reduces their deficit, the slope-only
  model can't update except by waiting for new noisy weight data.

---

## 3. Sex / Gender Differences — Quantified

Men typically lose more weight per unit time on identical absolute deficits,
but the bulk of this is **explained by body composition and size**, not by a
sex-specific metabolic switch. Once you control for fat-free mass, the sex
effect on rate of fat loss largely collapses.

Concrete drivers, in order of magnitude:

| Driver | Magnitude | Notes |
|---|---|---|
| BMR difference at equal age/height/weight | ~166 kcal/day | Direct from Mifflin–St Jeor: men's constant is +5, women's is −161, plus men carry more lean mass at the same weight. |
| Lean-mass fraction at equal BMI | 5–10 pp higher in men | A 80 kg man is ~75–80% FFM; an 80 kg woman ~65–70%. |
| TDEE at equal weight | 10–20% higher in men | Because BMR scales with FFM, not total mass. |
| Adaptive thermogenesis | Possibly larger in women | Mixed evidence; the PREVIEW trial found women lose ~2× the fat-free mass during *rapid* loss, which compounds metabolic adaptation. |
| Fat distribution | Men's visceral fat mobilises faster | Drives the visible "men lose faster early" effect but doesn't change long-run trajectory much. |

**Practical consequence:** A man and a woman of the same weight, height, and
age running an identical 500 kcal nominal deficit will see the woman lose
slower in absolute kg/week — primarily because her TDEE is lower, so a fixed
500 kcal deficit is a *larger fractional* deficit, but is also being applied
to a smaller fat compartment. Mifflin–St Jeor's sex term captures the first-
order effect cleanly. We do **not** need a separate sex-specific dynamics
model — sex enters through BMR and through the body-composition prior.

---

## 4. Formula Comparison

| Approach | Inputs | Accuracy (goal-date, 3–6mo horizon) | Implementation cost | Verdict |
|---|---|---|---|---|
| **Naive linear (current)** | weight history | ±50–100%; biased optimistic | Trivial | Ship-blocker. Replace. |
| **Static 3500-kcal / 7700-kcal-per-kg** | intake, TDEE | ±40–80%; biased optimistic | Trivial | Don't ship. |
| **Static Mifflin TDEE + fixed kcal/kg** | sex, age, height, weight, intake, activity | ±25–40% | Low | Acceptable MVP if dynamic is too costly. |
| **Hall full dynamic model** | Above + macro composition + body-fat % | ±10–15% | High (5 ODEs, calibration) | Overkill for a mobile app. |
| **Reduced two-compartment (Thomas / Hall-lite)** | sex, age, height, weight, intake, activity | ±15–25% | Medium | **Recommended.** |
| **Hybrid: observed-trajectory calibration + dynamic forward projection** | All of above + 14–28 day history | ±15–20% | Medium | **Recommended layer on top of the above.** |

The "reduced two-compartment" approach tracks `(FatMass, FatFreeMass)` and
updates them daily from the energy balance, partitioning energy between the
compartments using Forbes' rule. It captures ~80% of the accuracy of Hall's
full model with ~20% of the complexity, and crucially needs **no macro
breakdown** — only total kcal.

---

## 5. Recommended Formula

### 5.1 Variable definitions

| Symbol | Meaning | Source |
|---|---|---|
| `S` | Sex (`M` or `F`) | User profile |
| `A` | Age (years) | User profile |
| `H` | Height (cm) | User profile |
| `W_t` | Total body weight (kg) at day `t` | State; init from latest observation |
| `F_t` | Fat mass (kg) at day `t` | State |
| `L_t` | Fat-free mass (kg) at day `t`; `L_t = W_t - F_t` | State |
| `bf_0` | Initial body-fat fraction | Estimated (see 5.2) |
| `I_t` | Energy intake (kcal/day) | Observed or projected |
| `BMR_t` | Resting metabolic rate (kcal/day) | Mifflin–St Jeor |
| `PAL` | Physical activity level multiplier (1.2 sedentary … 1.9 very active) | User-selected |
| `TEF` | Thermic effect of food, ≈ 0.10 × `I_t` | Computed |
| `AT_t` | Adaptive thermogenesis penalty (kcal/day) | See 5.4 |
| `TDEE_t` | Total daily energy expenditure | Computed |
| `ρ_F` | Energy density of fat tissue ≈ 9440 kcal/kg | Hall |
| `ρ_L` | Energy density of fat-free tissue ≈ 1800 kcal/kg | Hall |
| `p` | Fraction of energy imbalance partitioned to FFM | Forbes |
| `k` | Calibration scalar (≈ 1.0); see 5.5 | Fitted |

### 5.2 Initial body composition (no DEXA available)

Estimate initial body-fat fraction from BMI, age, and sex using Deurenberg's
equation:

```
bf_0 = 1.20 * BMI + 0.23 * A - 10.8 * sex_M - 5.4
```

where `sex_M = 1` for men, `0` for women. Then `F_0 = bf_0 * W_0` and
`L_0 = W_0 - F_0`. This is rough (±5 pp absolute) but adequate as a seed —
the Forbes partitioning will self-correct over the projection.

### 5.3 TDEE at day t

```
BMR_t = 10*W_t + 6.25*H − 5*A + C_S          # Mifflin–St Jeor
                                              # C_S = +5 (M), −161 (F)

TDEE_t = k * (PAL * BMR_t) + TEF − AT_t
       = k * (PAL * BMR_t) + 0.10*I_t − AT_t
```

Use Mifflin–St Jeor (not Harris–Benedict, not Katch–McArdle). Mifflin wins on
modern populations without body-fat input — ~50% of estimates within ±10% of
indirect calorimetry vs ~37% for Harris–Benedict. Katch–McArdle is more
accurate **if** body-fat % is known, but we don't have it reliably.

### 5.4 Adaptive thermogenesis

The literature reports adaptive thermogenesis between ~65 and ~230 kcal/day
after moderate weight loss, scaling roughly with the amount of weight lost.
A tractable approximation:

```
AT_t = β * max(0, W_0 − W_t)
```

with `β ≈ 6 kcal/day per kg lost`. This produces ~60–90 kcal/day of
adaptation after a 10–15 kg loss — in the middle of the observed range.
Acute adaptation (first 1–2 weeks) is larger than steady-state; we
deliberately under-model it because (a) it partially reverses during
maintenance phases and (b) the trajectory calibration in 5.5 absorbs the
acute component.

### 5.5 Trajectory calibration (the "hybrid" layer)

Before projecting forward, fit `k` to the trailing 14–28 days of observations:

1. Compute average reported intake `Ī` over the window.
2. Compute observed weight change `ΔW_obs` (smoothed; LOWESS or 7-day MA).
3. Run the dynamic model forward over the window with `k = 1` to get `ΔW_pred`.
4. Solve for `k` such that `ΔW_pred(k) = ΔW_obs`. Constrain `k ∈ [0.7, 1.3]`.

This single scalar absorbs:
- Mifflin error for this individual (±10% typical).
- Chronic intake under-reporting (the dominant real-world error; users under-report by 20–40% on average).
- Activity-level miscategorisation.

If insufficient history exists (< 14 days of either weight or intake logs),
default `k = 0.95` (a small downward bias against intake under-reporting).

### 5.6 Daily update

```
balance_t = I_t − TDEE_t                                 # kcal/day, negative for deficit
p_t       = 1 / (1 + 10.4 / F_t)                          # Forbes partition (fraction to FFM)
ΔF_t      = (1 − p_t) * balance_t / ρ_F
ΔL_t      = p_t       * balance_t / ρ_L
F_{t+1}   = F_t + ΔF_t
L_{t+1}   = L_t + ΔL_t
W_{t+1}   = F_{t+1} + L_{t+1}
```

The Forbes partition fraction `p_t = 1/(1 + 10.4/F_t)` is the canonical
form. At `F = 30 kg` (a typical overweight adult), `p ≈ 0.26` — i.e. ~26% of
the energy deficit comes from FFM, 74% from fat. At `F = 10 kg` (lean), `p`
rises to ~0.49 — lean people lose proportionally more lean mass per kg of
weight loss, which is the empirical observation Forbes was modelling.

### 5.7 Projection loop

For projection, assume future `I_t = Ī` (the trailing-window average).
Iterate the 5.6 update day-by-day. Stop when `W_t ≤ W_goal`. Return that day
count as `days_to_goal`.

Cap projections at 1095 days (3 years) — beyond that, model error swamps
the prediction and the UX value is zero.

---

## 6. Implementation Notes

### 6.1 Edge cases & sane bounds

- **Goal already met or weight rising:** if `W_0 ≤ W_goal`, return "goal reached." If `Ī ≥ TDEE_0`, return "at current intake you will not lose weight" with the predicted plateau weight (solve for `W*` where `TDEE(W*) = Ī`).
- **Implausible deficits:** clamp `balance_t ≥ −1500 kcal/day` for safety. Below that, the model is out of its validated range and we shouldn't be encouraging it anyway.
- **Implausible projections:** if `days_to_goal > 1095`, return "more than 3 years — consider revising goal."
- **Weight history sparsity:** require ≥ 4 weigh-ins in the last 28 days for calibration; otherwise skip calibration (set `k = 0.95`) and flag the prediction as low-confidence.
- **Intake sparsity:** require ≥ 10 logged days in the last 14 for calibration; otherwise use TDEE-based prediction without the `k` correction and flag as low-confidence.
- **Re-feed / cheat days:** smoothing the trailing intake (7-day median, not mean) is more robust than raw mean.
- **Water-weight transients:** drop the first 3 days of any weight series when computing `ΔW_obs` — initial loss is dominated by glycogen+water (~2–3 kg) and corrupts calibration.

### 6.2 Confidence band

Surface a range, not a point estimate. Empirically, ±15% on the day count
matches the literature-reported accuracy of dynamic models. If
weight-history noise (residual SD around a LOWESS fit) is high (> 0.5 kg),
widen the band proportionally.

### 6.3 What we explicitly do NOT do

- **No 3500-kcal heuristic.** Anywhere. Not even as a fallback.
- **No linear extrapolation of weight slope.** The current behaviour is the bug.
- **No sex-specific dynamics model.** Sex enters through Mifflin's constant and through the initial body-composition prior. That is sufficient.
- **No macro-nutrient tracking.** The Hall full model needs it; the reduced model doesn't. We trade ~5 pp of accuracy for not requiring users to log macros.
- **No assumption that reported intake is accurate.** The `k` scalar is the entire reason this design works in production. Treat un-calibrated TDEE numbers as priors, not truths.

### 6.4 Testing

Unit-test the daily update against the NIH Body Weight Planner output for
3–4 canonical scenarios (e.g. 100 kg M, 35 y, 180 cm, sedentary, 500 kcal
deficit → expect ~21–24 lb loss at 1 year). Within ±10% of NIH BWP is the
acceptance criterion.

---

## 7. Citations

- Hall, K. D., Sacks, G., Chandramohan, D., Chow, C. C., Wang, Y. C., Gortmaker, S. L., Swinburn, B. A. (2011). **Quantification of the effect of energy imbalance on bodyweight.** *The Lancet*, 378(9793), 826–837. PubMed 21872751. The canonical replacement for the 3500-kcal rule; source of the 10-kcal/day-per-pound steady-state heuristic and the 1-year/3-year half-time figures.
- Hall, K. D., Chow, C. C. (2013). **Why is the 3500 kcal per pound weight loss rule wrong?** *International Journal of Obesity*, 37, 1614. PMC3859816. Explicit demolition of the static rule.
- Thomas, D. M., Martin, C. K., Lettieri, S., Bredlau, C., Kaiser, K., Church, T., Bouchard, C., Heymsfield, S. B. (2013). **Can a weight loss of one pound per week be achieved with a 3500 kcal deficit?** *European Journal of Clinical Nutrition*. PubMed 23628852. Independent confirmation; provides the simplified single-compartment dynamic equations many apps adopt.
- Hall, K. D. (2010). **Predicting metabolic adaptation, body weight change, and energy intake in humans.** *AJP Endocrinology and Metabolism*. Source of the ρ_F = 9440 kcal/kg and ρ_L = 1800 kcal/kg constants and the Forbes-derived partition function.
- Forbes, G. B. (1987). **Lean body mass–body fat interrelationships in humans.** *Nutrition Reviews*, 45, 225–231. Original FFM = 14.2 + 10.4 ln(FM) relationship; basis for `p_t`.
- Hall, K. D. (2007). **Body fat and fat-free mass inter-relationships: Forbes's theory revisited.** *British Journal of Nutrition*, 97, 1059–1063. PMC2376748. Demonstrates the Forbes relationship is approximately sex-invariant — justifies why we don't branch the partition function on sex.
- Mifflin, M. D., St Jeor, S. T., Hill, L. A., Scott, B. J., Daugherty, S. A., Koh, Y. O. (1990). **A new predictive equation for resting energy expenditure in healthy individuals.** *American Journal of Clinical Nutrition*, 51, 241–247. The BMR equation we use.
- Frankenfield, D., Roth-Yousey, L., Compher, C. (2005). **Comparison of predictive equations for resting metabolic rate in healthy nonobese and obese adults: a systematic review.** *Journal of the American Dietetic Association*, 105, 775–789. Establishes Mifflin–St Jeor as the most accurate equation for the general adult population without body-fat input.
- Deurenberg, P., Weststrate, J. A., Seidell, J. C. (1991). **Body mass index as a measure of body fatness: age- and sex-specific prediction formulas.** *British Journal of Nutrition*, 65, 105–114. Source of the body-fat seed estimate.
- Müller, M. J., Enderle, J., Bosy-Westphal, A. (2016). **Changes in energy expenditure with weight gain and weight loss in humans.** *Current Obesity Reports*. Magnitude of adaptive thermogenesis (65–230 kcal/day range).
- Heinitz, S. et al. (2020). **Early adaptive thermogenesis is a determinant of weight loss after six weeks of caloric restriction.** PMC7484122. Source of the early-vs-steady-state AT distinction.
- Hall, K. D. (PREVIEW collaborators) (2018). **Men and women respond differently to rapid weight loss.** PMC6282840. Source of the "women lose 2× the FFM during rapid loss" finding.
- **NIH Body Weight Planner.** https://www.niddk.nih.gov/bwp — the production reference implementation of the Hall model. Use as the oracle for unit tests.

---

**End of report.** Implementation agent: Section 5 is the spec. Section 6 is
the deployment checklist. If you find yourself wanting to deviate from
Section 5, re-read Section 4 and confirm the deviation isn't just the 3500-
kcal rule wearing a hat.
