# src/institutions/Construction.jl

#
# Dynamic housing-supply module.
#
# Java reference : src/legacy_codebase/java/housing/Construction.java
# Java call site : Model.java  modelStep()  line 187 — called unconditionally every tick.
#
# Execution mode : DYNAMIC — construction_step! runs on every model step with no flag guard.
#
# ============================================================================
# Java Architecture Notes
# ============================================================================
#
# Java's Construction class implements IHouseOwner so it can register house-sale
# offers directly with HouseSaleMarket.  Key fields:
#
#   housingStock (int)   — running count of all houses ever created.
#   nNewBuild    (int)   — new houses added in the current month.
#   onMarket (HashSet)   — houses listed by Construction as seller.
#                          *** DEAD CODE in Java: onMarket.add() is never called.
#                          Construction.step() calls inheritHouse() which
#                          immediately transfers ownership to a Household object,
#                          so Construction is never the IHouseOwner of any listing.
#                          The 5 % monthly price-cut loop (lines 44-46) iterates
#                          an always-empty set and is therefore a no-op. ***
#
# Julia omits on_market entirely.  All sale-listing price reductions (including
# those for construction-originated houses) are handled by update_for_sale_supply!
# in HousingMarket.jl, which already covers every listing in active_sales_listings.
#
# ============================================================================
# Role of this module — Elastic Supply Valve
# ============================================================================
#
# This module is the elastic supply valve for all scenarios where the inelastic
# supply assumption is relaxed or broken.  In the Carro et al. (2022) baseline
# it is intentionally idle: the paper calibrates to the UK market and explicitly
# assumes inelastic housing supply, so the stock is fixed at initialisation and
# construction_step! is a no-op every tick.
#
# The module fires (shortfall > 0) under exactly four conditions:
#
#   1. Initialisation mismatch
#      Run with n_houses < floor(N_HH × HOUSES_PER_HOUSEHOLD).
#      Construction fills the gap on tick 1, then stays idle.
#
#   2. Population-growth experiments
#      Raise n_households dynamically (e.g. to model immigration) so that the
#      target stock increases each step and a shortfall opens.  To allow stock
#      to grow with the actual population rather than the parameter ceiling,
#      replace the min() cap in construction_step! with effective_n = nagents(model).
#
#   3. Housing-destruction mechanism
#      If a future demolition or disaster module calls pop! / deleteat! on
#      housing_stock, housing_stock_count drops below target and construction
#      automatically rebuilds the deficit the following tick.
#
#   4. Elastic-supply counterfactual research
#      The central sensitivity experiment in Carro et al.: does elastic supply
#      dampen house-price cycles?  Enabling construction with a non-zero
#      responsiveness parameter produces the elastic-supply counterfactual
#      against the inelastic baseline.
#
# Why it is idle in the current baseline
# ----------------------------------------
# Houses are never destroyed: process_death! (Demographics.jl) transfers all of
# a deceased agent's properties to a beneficiary via inherit_house! and never
# removes entries from housing_stock.  As a result length(housing_stock) is
# strictly monotone non-decreasing, the shortfall never becomes positive after
# initialisation, and n_new_build stays 0 every tick — exactly as the paper
# specifies.
#
# ============================================================================
# Java step() pseudocode  (Construction.java lines 40–69)
# ============================================================================
#
# ```java
# public void step() {
#     nNewBuild = 0;
#     // [lines 44-46] 5 % price-cut loop — dead code, onMarket always empty
#     for (House h : onMarket) { houseSaleMarket.updateOffer(h, h.price * 0.95); }
#
#     int targetStock = (int)(
#         Math.floor(households.size() < TARGET_POPULATION
#             ? households.size() * HOUSES_PER_HOUSEHOLD
#             : TARGET_POPULATION * HOUSES_PER_HOUSEHOLD)
#     );
#     int shortFall = targetStock - housingStock;
#     if (shortFall > 0) nNewBuild += shortFall;
#
#     while (shortFall > 0) {
#         House newHouse = new House((int)(prng.nextDouble() * N_QUALITIES));
#         houseSaleMarket.offer(newHouse, ...);   // Construction is seller
#         housingStock++;
#         households.get(prng.nextInt(size)).inheritHouse(newHouse, refPrice);
#         --shortFall;
#     }
# }
# ```

export construction_step!

# ============================================================================
# Module-level docstring
# ============================================================================

"""
    construction_step!(model)

Dynamic housing-supply step.  Called unconditionally on every tick by
`model_step!` in `Scheduler.jl` (Java parity: `Model.java` line 187).

## What it does

Mirrors `Construction.java step()` (lines 40–69):

1. **Reset** `n_new_build` to 0.
2. **Compute target stock**: `floor(min(nagents, n_households) × HOUSES_PER_HOUSEHOLD)`.
3. **Fill shortfall**: if `target > housing_stock_count`, create `shortfall` new
   `House` objects, push them onto `model.housing_stock`, call `inherit_house!`
   to assign each to a randomly chosen household, and increment
   `housing_stock_count`.

## Invariants maintained

- `model.construction.housing_stock_count == length(model.housing_stock)` after
  every call.
- `n_new_build ≥ 0` always.
- Stock is monotonically non-decreasing (construction never removes houses).
- In a stationary population (`nagents == n_households`) the shortfall is 0
  after initialisation and `n_new_build` stays 0 every tick.

## Java dead code omitted

`Construction.java` contains a `5 %` price-cut loop over `onMarket` (lines 44-46)
and a `completeHouseSale` callback (line 77).  Both are inoperative because
`onMarket` has no `.add()` call anywhere in the Java file — `inheritHouse()`
immediately transfers ownership to a `Household`, so `Construction` is never
registered as seller.  Julia omits `on_market` entirely; all listing price
reductions are handled by `update_for_sale_supply!` in `HousingMarket.jl`.

## Java reference

```java
// Construction.java  lines 40–69  (simplified)
public void step() {
    nNewBuild = 0;
    int targetStock = (int) Math.floor(
        Math.min(households.size(), TARGET_POPULATION) * HOUSES_PER_HOUSEHOLD);
    int shortFall = targetStock - housingStock;
    if (shortFall > 0) nNewBuild += shortFall;
    while (shortFall > 0) {
        House h = new House((int)(prng.nextDouble() * N_QUALITIES));
        households.get(prng.nextInt(size)).inheritHouse(h, refPrice);
        housingStock++;
        --shortFall;
    }
}
```
"""
function construction_step!(model)

    # ------------------------------------------------------------------
    # 0. Reset monthly new-build counter
    #    Java: nNewBuild = 0;  (Construction.java line 42)
    # ------------------------------------------------------------------
    model.construction.n_new_build = 0

    # ------------------------------------------------------------------
    # 1. Target housing-stock calculation
    #    Java: Construction.java lines 48–54.
    #    NOTE: Java's onMarket / 5 % price-cut loop (lines 44–46) is dead
    #    code — onMarket is never populated in Construction.java.  All
    #    price reductions are handled by update_for_sale_supply! in
    #    HousingMarket.jl, which already covers construction-originated
    #    listings.  See Construction struct docstring in Types.jl.
    # ------------------------------------------------------------------
    n_current_hh  = nagents(model)
    target_pop    = model.params.n_households        # Java: config.TARGET_POPULATION
    houses_per_hh = model.houses_per_household

    # Java: if(households.size() < TARGET_POPULATION) use size(), else TARGET_POPULATION
    effective_n  = min(n_current_hh, target_pop)
    target_stock = Int(floor(effective_n * houses_per_hh))

    # ------------------------------------------------------------------
    # 2. Shortfall
    #    Java: int shortFall = targetStock - housingStock;  (line 56)
    # ------------------------------------------------------------------
    shortfall = target_stock - model.construction.housing_stock_count

    # Accumulate new-build count (Java: nNewBuild += shortFall; line 59)
    if shortfall > 0
        model.construction.n_new_build += shortfall
    end

    # ------------------------------------------------------------------
    # 3. New-build delivery loop
    #    Java: Construction.java lines 62–69.
    # ------------------------------------------------------------------
    # Pre-collect agent IDs once outside the loop — O(1) per iteration.
    # Java: prng.nextInt(Model.households.size())
    all_ids = collect(allids(model))

    while shortfall > 0

        # 3a. Assign quality uniformly at random
        #     Java: new House((int)(prng.nextDouble() * N_QUALITIES))
        #     Java returns 0-based index [0, N-1]; Julia uses 1-based [1, N].
        quality = Int(floor(rand(abmrng(model)) * model.params.n_qualities)) + 1

        # 3b. Reference price / rent for this quality band
        #     Java: housingMarketStats.getReferencePriceForQuality(quality)
        ref_price = model.market_stats.reference_prices_by_quality[quality]
        ref_rent  = model.market_stats.reference_rents_by_quality[quality]

        # 3c. Create the House object
        new_id    = length(model.housing_stock) + 1
        new_house = House(
            new_id,     # id
            quality,    # quality (const field)
            nothing,    # owner_id  — set by inherit_house!
            nothing,    # resident_id
            false,      # is_for_sale
            ref_price,  # listing_price (reference valuation at birth)
            0,          # months_on_market
            false,      # is_for_rent
            ref_rent,   # rental_price
            0           # months_on_rental_market
        )
        push!(model.housing_stock, new_house)

        # 3d. Assign via household-inheritance mechanism
        #     Java: households.get(prng.nextInt(size)).inheritHouse(newHouse, refPrice)
        #     inherit_house! handles OO / BTL / homeless decisions and calls
        #     put_on_market! for any surplus property — no on_market tracking needed here.
        owner_id = rand(abmrng(model), all_ids)
        inherit_house!(model[owner_id], new_house, model)

        # 3e. Update counters
        model.construction.housing_stock_count += 1
        shortfall -= 1
    end
end
