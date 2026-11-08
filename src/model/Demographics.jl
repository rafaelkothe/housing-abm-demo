# src/model/Demographics.jl
#
# Household demography: ageing, birth, death, inheritance and household formation.
#   - demographics_step!      monthly stationary-population update (ageing, births, deaths)
#   - process_death!          mortgage discharge and transfer of wealth and houses to an heir
#   - inherit_house!          decides whether the heir lives in, sells or rents out an inherited house
#   - create_new_household!   draws the attributes of a newborn household
#   - sample_investor_delta   draws the buy-to-let investor type
# The population is kept stationary: each month the number of households in every monthly age bin
# is moved back to the target held in model.demographics, as in Carro et al. (2022), Section 3.1
# and Appendix A.2.

"""
    demographics_step!(model)

Apply the stationary-population mechanism of Carro et al. (2022), Section 3.1 and Appendix A.2.
Instead of biological dynamics, the number of households in each monthly age bin is forced back to the
fixed target `model.demographics.expected_per_bin`.

Order of operations (as in Demographics.java:42-49):
1. Ageing: every household ages by one month.
2. Births: each bin below its target is refilled with new households.
3. Deaths: each bin above its target loses households chosen at random; households beyond the
   maximum age always die.

Births precede deaths so that newborn households cannot be selected as death candidates in the same
step. Each death is followed by the transfer of the estate to a randomly drawn heir
(see `process_death!`).

Mutates `model`: household ages, the set of agents, and everything touched by `process_death!`.
"""
function demographics_step!(model)
    rng = abmrng(model)
    # ------------------------------------------------------------------
    # Ageing
    # ------------------------------------------------------------------
    # Each time step is one month, so every household ages by 1/12 years.
    for agent in allagents(model)
        agent.age += 1.0 / 12.0
    end

    # ------------------------------------------------------------------
    # Population balancing (stationary population)
    # ------------------------------------------------------------------
    # Monthly age distribution derived from smoothed empirical data.
    demo_data = model.demographics
    monthly_width = demo_data.monthly_bin_width
    min_age = Float64(demo_data.raw_bins[1][1])
    
    n_bins = length(demo_data.monthly_probs)
    
    # Target counts are fixed at initialisation (Java: data.Demographics.expectedHouseholdsPerAgeBand);
    # they do not scale with the current population.
    target_counts = demo_data.expected_per_bin
    
    # Current number of households in each monthly age bin
    current_counts = zeros(Int, n_bins)
    
    # Bucket agents into monthly bins (one pass over all agents).
    for agent in allagents(model)
        age = agent.age
        
        # Determine the monthly bin index for the agent's current age.
        if age < min_age
            current_counts[1] += 1
        else
            idx = floor(Int, (age - min_age) / monthly_width) + 1
            if idx > n_bins
                current_counts[n_bins] += 1
            else
                current_counts[idx] += 1
            end
        end
    end

    # ------------------------------------------------------------------
    # Balancing: births before deaths (Java order)
    # ------------------------------------------------------------------
    
    # Number of births and deaths required per bin, computed up front
    kill_targets = zeros(Int, n_bins + 1)  # +1 for over-max-age bin
    birth_targets = zeros(Int, n_bins)
    
    for i in 1:n_bins
        diff = current_counts[i] - target_counts[i]
        if diff > 0.5
            kill_targets[i] = round(Int, diff)
        elseif diff < -0.5
            birth_targets[i] = round(Int, abs(diff))
        end
    end
    
    # Households beyond the maximum age die with certainty (Java: deathProbabilities[n_bins] = 1.0)
    max_valid_age = min_age + n_bins * monthly_width
    n_over_age = 0
    for agent in allagents(model)
        if agent.age >= max_valid_age
            n_over_age += 1
        end
    end
    kill_targets[n_bins + 1] = n_over_age
    
    # Births (before deaths, as in Java)
    for i in 1:n_bins
        n = birth_targets[i]
        if n > 0
            for _ in 1:n
                create_new_household!(model, i)
            end
        end
    end
    
    # Deaths (after births, as in Java). Each household in a bin above target dies with probability
    # kill_target / current count, as in Java: if (prng.nextDouble() < deathProbabilities[i]).
    if sum(kill_targets) > 0
        # Candidates are visited in the order of the agent container (Demographics.java:115 iterates
        # the household list in insertion order); the candidate list is not shuffled, so no random
        # numbers are consumed before the first death probability is evaluated.
        # ND38_SORTED_DEATH_LOOP = true visits candidates in ascending id order instead; the default
        # (false) keeps the container order. See Config.jl.
        death_candidate_ids = Config.ND38_SORTED_DEATH_LOOP ?
            sort!(collect(allids(model))) : collect(allids(model))

        # Alias rather than copy: current_counts is not read after this point.
        current_bin_counts = current_counts

        for ag_id in death_candidate_ids
            # The id list is a snapshot, so skip any id that is no longer in the model.
            if ag_id ∉ allids(model); continue; end
            agent = model[ag_id]
            age = agent.age
            
            # Determine bin index
            b_idx = 1
            if age >= min_age
                b_idx = floor(Int, (age - min_age) / monthly_width) + 1
                if b_idx > n_bins
                    b_idx = n_bins + 1  # Over-max-age bin
                end
            end
            
            death_probability = 0.0
            if b_idx == n_bins + 1
                # Over the maximum age: certain death
                death_probability = 1.0
            elseif kill_targets[b_idx] > 0 && current_bin_counts[b_idx] > 0
                death_probability = kill_targets[b_idx] / current_bin_counts[b_idx]
            end
            
            if rand(rng) < death_probability
                # As in Demographics.java:120-122, the deceased is removed (iterator.remove())
                # before the heir is drawn (prng.nextInt(Model.households.size())), so the heir is
                # drawn from the N-1 remaining households and cannot be the deceased.
                remove_agent!(agent, model)

                # Exactly one random draw selects the heir. If the deceased was the last household,
                # there is no heir; process_death! then still discharges the mortgages and only
                # skips the transfer of wealth and houses.
                beneficiary = nagents(model) > 0 ? random_agent(model) : nothing
                process_death!(agent, beneficiary, model)

                # Update the remaining targets and counts so that the bin is not over-depleted
                if b_idx <= n_bins
                    kill_targets[b_idx] -= 1
                    current_bin_counts[b_idx] -= 1
                    # The death probability of the next candidate in this bin is recomputed from
                    # the updated counts by the division above.
                    if current_bin_counts[b_idx] > 0
                        # (no action needed)
                    end
                else
                    kill_targets[b_idx] -= 1
                end
            end
        end
    end
end

"""
    inherit_house!(beneficiary, house, model)

Transfer ownership of `house` (inherited mortgage-free) to `beneficiary` and decide how it is used.

- A social-housing tenant or renter moves in as owner-occupier. A renter first ends the lease on the
  rental house, which is relisted on the rental market (if `Config.ND31_RELIST_ON_TENANT_EXIT` is set
  and its landlord is still in the model). A first-time buyer becomes a home mover.
- An existing owner-occupier holds a surplus house. A buy-to-let investor sells it if
  `evaluate_investor_exit` says so; any other owner must sell it. Sales are listed with
  `put_on_market!`. A house that is not already for rent is also listed for rent at a market-based rent.

Mutates `beneficiary`, `house` and the listing sets and rental counters in `model.market_stats`.
"""
function inherit_house!(beneficiary, house, model)
    # --- 1. Transfer title ---
    # The heir receives the house free of mortgage.
    house.owner_id = beneficiary.id
    push!(beneficiary.properties_owned, house.id)
    
    # --- 2. Heir decision ---
    if beneficiary.tenure_status == SocialHousing || beneficiary.tenure_status == Renter
        # Scenario 1: the heir needs a home and moves in immediately.
        
        # If a renter, end the lease first.
        if beneficiary.tenure_status == Renter && beneficiary.rental_agreement !== nothing
            old_house_id = beneficiary.residence_id
            if old_house_id !== nothing
                 # housing_stock is append-only, so any stored residence_id is a valid index;
                 # the assertion checks data consistency.
                 @assert 1 <= old_house_id <= length(model.housing_stock) "Stale residence_id $old_house_id not in housing_stock"
                 old_rental = model.housing_stock[old_house_id]
                 old_rental.resident_id = nothing

                 # Relist the vacated rental house at a fresh market rent, as the Java chain
                 # Household.endTenancy() -> owner.endOfLettingAgreement(...) ->
                 # HouseRentalMarket.offer(h, behaviour.getInitialRentPrice(q), false) does.
                 # The same steps are applied in `process_death!` and in the lease-expiry path of
                 # FinancialFlows.jl. Controlled by `Config.ND31_RELIST_ON_TENANT_EXIT`.
                 if Config.ND31_RELIST_ON_TENANT_EXIT &&
                    old_rental.owner_id !== nothing &&
                    old_rental.owner_id in allids(model)

                     q = old_rental.quality
                     r_Q = model.market_stats.ema_rents_by_quality[q]
                     eta = draw_rental_markup(model)
                     if r_Q > 0.0
                         old_rental.rental_price = r_Q * eta
                     end
                     old_rental.months_on_rental_market = 0
                     old_rental.is_for_rent = true
                     push!(model.market_stats.active_rental_listings, old_rental.id)

                     # One occupied rental becomes vacant: decrement occupied, increment vacant.
                     if 1 <= q <= length(model.market_stats.occupied_rentals_by_quality)
                         model.market_stats.occupied_rentals_by_quality[q] =
                             max(0, model.market_stats.occupied_rentals_by_quality[q] - 1)
                     end
                     if 1 <= q <= length(model.market_stats.vacant_rentals_by_quality)
                         model.market_stats.vacant_rentals_by_quality[q] += 1
                     end
                 end
            end
            beneficiary.rental_agreement = nothing
        end
        
        # Move in
        beneficiary.residence_id = house.id
        # Update status
        beneficiary.tenure_status = OwnerOccupier
        if beneficiary.borrower_type == FTB
            beneficiary.borrower_type = HM # Inheriting a house ends first-time-buyer status
        end
        
        house.resident_id = beneficiary.id
        house.is_for_sale = false
        house.is_for_rent = false 
        delete!(model.market_stats.active_sales_listings, house.id)
        delete!(model.market_stats.active_rental_listings, house.id)
        
    else
        # Scenario 2: surplus property (the heir is already an owner-occupier)
        
        if beneficiary.is_btl_investor
            # Buy-to-let investor: keep or sell depending on the investor exit decision
            sell_decision = evaluate_investor_exit(beneficiary, house, model)
            
            if sell_decision
                # put_on_market! sets the listing price as Java's putHouseForSale(h) does via
                # getInitialSalePrice(quality, principal): a markup draw on the expected average
                # sale price for the quality, floored at the outstanding principal.
                put_on_market!(house, model)
            else
                # Kept: make sure it is not listed for sale (the previous owner may have listed it).
                house.is_for_sale = false
                delete!(model.market_stats.active_sales_listings, house.id)
            end
        else
            # Owner-occupier with a surplus house: must sell.
            # put_on_market! sets the listing price (Java: putHouseForSale(h) via getInitialSalePrice()).
            put_on_market!(house, model)
        end
        
        # Rental listing of the inherited house. Java: Model.houseRentalMarket.offer(h,
        # behaviour.getInitialRentPrice(quality), false), i.e. a rent markup draw on the expected
        # rent for the quality; here draw_rental_markup * ema_rents_by_quality.
        if !house.is_for_rent
            # Set the rental price before listing; fall back to INITIAL_AVG_RENT if no average rent exists yet.
            base_rent = model.market_stats.ema_rents_by_quality[house.quality]
            if base_rent <= 0.0; base_rent = Config.INITIAL_AVG_RENT; end
            eta = draw_rental_markup(model)
            house.rental_price = base_rent * eta
            
            house.is_for_rent = true
            house.months_on_rental_market = 0
            push!(model.market_stats.active_rental_listings, house.id)
            # Guard the quality index before updating the vacant counter
            if 1 <= house.quality <= length(model.market_stats.vacant_rentals_by_quality)
                model.market_stats.vacant_rentals_by_quality[house.quality] += 1
            end
        end
    end
end

"""
    process_death!(dead_agent, beneficiary, model)

Settle the estate of a household that has already been removed from the model by `remove_agent!`.

Steps:
1. If the deceased was a renter, clear the resident link of the rental house, end the rental
   agreement and relist the house on the rental market.
2. Discharge every mortgage held, in ascending house id order, from the deceased's bank balance
   (see the comments in the body for the payment rules and the bank accounting).
3. Discharge any residual loans in `zombie_debts` (only populated when `Config.D3_ZOMBIE_DEBT` is set).
4. If `beneficiary` is not `nothing`: evict tenants from the deceased's houses, clear their listings,
   pass each house to `inherit_house!`, and transfer any positive remaining bank balance.

`beneficiary` is drawn by the caller after the deceased has been removed (Demographics.java:120-122), so
it is never the deceased. It is `nothing` only if the deceased was the last household; the debts are then
still discharged.

Mutates `dead_agent`, `beneficiary`, the houses involved, `model.bank` and `model.market_stats`.
"""
function process_death!(dead_agent, beneficiary, model)
    # =========================================================================
    # Deceased renter: release the rental house
    # =========================================================================
    # Java: Household.java:514-518 (transferAllWealthTo, loop branch).
    # A deceased renter's residence_id refers to a house they do not own; the house's resident link
    # and the landlord's records must be cleared to avoid dangling references.
    
    if dead_agent.tenure_status == Renter && dead_agent.residence_id !== nothing
        rental_house_id = dead_agent.residence_id
        
        # Bounds check (housing_stock is append-only, so all IDs are valid)
        if 1 <= rental_house_id <= length(model.housing_stock)
            rental_house = model.housing_stock[rental_house_id]
            
            # Clear the house's resident link
            rental_house.resident_id = nothing
            
            # Terminate rental agreement
            dead_agent.rental_agreement = nothing
            
            # Notify landlord (end of tenancy)
            # Java: h.owner.endOfLettingAgreement(h, housePayments.get(h))
            if rental_house.owner_id !== nothing && rental_house.owner_id in allids(model)
                landlord = model[rental_house.owner_id]
                
                # Relist the house on the rental market.
                # Java: HouseRentalMarket.offer(h, getInitialRentPrice(h.getQuality()), false) creates
                # a new listing with:
                #   - initialListingTime = getTime(), so the grace-period counter restarts at 0
                #   - price = getInitialRentPrice(q), the average rent for the quality times a fresh markup draw
                # The three blocks below reproduce this and match the lease-expiry relisting path in
                # FinancialFlows.jl.
                #
                # Java's endOfLettingAgreement() is the same for every landlord type, so owner-occupier
                # landlords (who can hold rental stock acquired by inheritance) relist as well as
                # buy-to-let investors. `Config.ND31_RELIST_ON_TENANT_EXIT` (default true) selects this;
                # when false only buy-to-let landlords relist.
                should_relist = Config.ND31_RELIST_ON_TENANT_EXIT ?
                                true :
                                landlord.is_btl_investor
                if should_relist
                    q = rental_house.quality

                    # Restart the vacancy timer. The grace-period check in update_rental_supply!
                    # skips rent reductions while months_on_rental_market <= 1, which corresponds to
                    # Java's initialListingTime == getTime() for a new listing.
                    rental_house.months_on_rental_market = 0

                    # Reset the asking rent to the current market level.
                    # Java: getInitialRentPrice(q) = expAvRentalPricePerQuality[q] x eta, with eta drawn
                    # from the initial rent markup distribution. The contract rent of the previous
                    # tenant is not reused. Same logic as the lease-expiry path in FinancialFlows.jl.
                    r_Q = model.market_stats.ema_rents_by_quality[q]
                    eta = draw_rental_markup(model)
                    if r_Q > 0.0
                        rental_house.rental_price = r_Q * eta
                    end

                    rental_house.is_for_rent = true
                    push!(model.market_stats.active_rental_listings, rental_house.id)

                    # Keep the occupied/vacant counters consistent: the house moves from occupied to
                    # vacant (Java: endOfLettingAgreement() lowers the occupied count before
                    # offer() adds a vacancy). Same paired update as in FinancialFlows.jl.
                    if 1 <= q <= length(model.market_stats.occupied_rentals_by_quality)
                        model.market_stats.occupied_rentals_by_quality[q] =
                            max(0, model.market_stats.occupied_rentals_by_quality[q] - 1)
                    end
                    if 1 <= q <= length(model.market_stats.vacant_rentals_by_quality)
                        model.market_stats.vacant_rentals_by_quality[q] += 1
                    end
                end
            end
        end
    end
    
    # Mortgage discharge
    # -------------------
    # Rule (Carro et al. 2022, Appendix A.2): outstanding mortgages are paid off as far as possible
    # from the deceased's financial wealth; any remaining debt is written off. For each mortgage,
    # payment = min(bank_balance, outstanding).
    #
    # Java (Household.java:538-541, transferAllWealthTo) calls payoff() without an argument, which is
    # payoff(principal) (MortgageAgreement.java:87). That always discharges the full principal and ends
    # the mortgage contract, so the balance can become negative; Math.max(0.0, bankBalance) then floors
    # the heir's inheritance at zero. Example with two mortgages of 6k and a balance of 10k:
    #   Java:         pays 12k in total (balance -2k), the heir receives 0.
    #   Capped rule:  pays 10k (6k + 4k), writes off 2k, the heir receives 0.
    #
    # Two independent settings in Config.jl govern this path:
    #   - Payment cap, `D4_INHERITANCE_OVERPAY`. false (default): payment = min(bank_balance, outstanding),
    #     as in the paper. true: payment = outstanding, as in Java.
    #   - Residual loans, `D3_ZOMBIE_DEBT`. No residual loan is created at death under either setting:
    #     `mortgages_held` is emptied. Residual loans left by an earlier house sale (only possible when
    #     D3_ZOMBIE_DEBT is true) are discharged in the block after the loop.
    # In both cases `bank.outstanding_credit` falls by the full outstanding amount of each mortgage.
    #
    # The discharge is between the estate and the bank and does not depend on there being an heir, so
    # it runs before the `beneficiary !== nothing` check. Java's payoff loop likewise runs
    # unconditionally; skipping it would leave `bank.outstanding_credit` inflated by the unpaid principal.
    #
    # Mortgages are processed in ascending house id order. Java keeps them in a
    # TreeMap<House, PaymentAgreement> (Household.java:36) ordered by House.compareTo, which compares
    # ids (House.java:63). The paper does not specify a priority between mortgages. Since
    # sum_i min(b0 - sum_{j<i} p_j, o_i) = min(b0, sum_i o_i), the total paid and the total written off
    # do not depend on the order; sorting by house id makes the per-mortgage sequence match Java.

    for mortgage in sort(dead_agent.mortgages_held, by = m -> m.house_id)
         outstanding = mortgage.remaining_principal

         # 1. Payment.
         #    D4_INHERITANCE_OVERPAY = false (default, Appendix A.2):
         #      payment = min(bank_balance, outstanding), so the balance stays non-negative.
         #      shortfall = outstanding - payment >= 0 is written off (see below).
         #    D4_INHERITANCE_OVERPAY = true (Java, Household.java:540):
         #      payment = outstanding, as payoff() = payoff(principal). The balance may become
         #      negative across the loop; the heir transfer below ignores a negative balance,
         #      as Java's Math.max(0.0, bankBalance) does (Household.java:546).
         payment = Config.D4_INHERITANCE_OVERPAY ? outstanding : min(dead_agent.bank_balance, outstanding)

         # 2. Cash flows: the deceased pays the bank what the rule above prescribes.
         #    Change in dead_agent.bank_balance = -payment
         #    Change in bank.cash_reserves      = +payment
         dead_agent.bank_balance -= payment
         model.bank.cash_reserves += payment

         # 3. Write off the shortfall.
         #    shortfall = outstanding - payment (zero when the balance covered the mortgage).
         #    bank.outstanding_credit falls by the full outstanding amount (step 4), while only
         #    `payment` is received in cash, so the bank's net position changes by -shortfall.
         #    There is no provision or loan-loss reserve field on the bank; the shortfall is
         #    accumulated in bank.cumulative_inheritance_writeoffs.
         shortfall = outstanding - payment
         if shortfall > 0
             # Accumulate the write-off. Always zero when D4_INHERITANCE_OVERPAY is true,
             # because payment = outstanding then.
             model.bank.cumulative_inheritance_writeoffs += shortfall
         end

         # 4. Remove the full outstanding amount from the bank's credit assets.
         model.bank.outstanding_credit -= outstanding
    end

    empty!(dead_agent.mortgages_held)

    # --- Residual loans of the deceased (Config.D3_ZOMBIE_DEBT) -------------------------------
    # Java (Household.java:509-542, transferAllWealthTo) iterates the whole housePayments map, which
    # also holds residual loans from earlier sales (houses the deceased no longer owns), and calls
    # payoff() on each, fully discharging every one at death.
    #
    # With D3_ZOMBIE_DEBT = true, dead_agent.zombie_debts can be non-empty (a residual left when the
    # sale proceeds were below the remaining principal). Each is fully discharged here, with the
    # deceased's balance reduced and the bank's cash reserves increased by the remaining principal.
    #
    # bank.outstanding_credit is not touched: execute_transaction! (HousingMarket.jl) already reduced
    # it by the full remaining principal at the time of sale, so each mortgage is deducted exactly once.
    # (Java defers that deduction to endMortgageContract() inside payoff().)
    #
    # With D3_ZOMBIE_DEBT = false, zombie_debts is always empty and this block does nothing.
    if Config.D3_ZOMBIE_DEBT && !isempty(dead_agent.zombie_debts)
        for zm in dead_agent.zombie_debts
            # Credit only cash reserves; outstanding_credit was already reduced at the sale
            dead_agent.bank_balance  -= zm.remaining_principal
            model.bank.cash_reserves += zm.remaining_principal
        end
        empty!(dead_agent.zombie_debts)
    end

    if beneficiary !== nothing
        # Transfer houses and remaining financial wealth to the heir.
        # -----------------------------------------------------------
        # 1. Transfer all owned houses.
        # dead_agent.properties_owned is iterated directly, without copying: inherit_house! changes
        # only beneficiary.properties_owned, so the source vector is not modified during the loop.
        # The deceased is already detached from the model (the caller removed it), so its fields
        # can still be read safely.
        #
        # With ND39_SORTED_PROPERTY_DISPOSITION = true (default) houses are visited in ascending id
        # order. Java (Household.java:634) iterates `housePayments.keySet()` of a TreeMap<House>,
        # which is id-ordered, whereas properties_owned holds acquisition order. The order matters:
        # the first house visited becomes the heir's residence (Scenario 1 of inherit_house!), and
        # later ones go to the market (Scenario 2), which also consumes random draws.
        property_iter = Config.ND39_SORTED_PROPERTY_DISPOSITION ?
            sort(dead_agent.properties_owned) : dead_agent.properties_owned
        for house_id in property_iter
            house = model.housing_stock[house_id]
            
            # --- 1. Mandatory eviction ---
            # Tenants of the deceased's investment properties are evicted (Carro et al. 2022, Appendix A.2).
            if house.resident_id !== nothing && house.resident_id != dead_agent.id
                tenant_id = house.resident_id
                if tenant_id in allids(model)
                    tenant = model[tenant_id]
                    tenant.residence_id = nothing
                    tenant.rental_agreement = nothing
                    tenant.tenure_status = SocialHousing # The evicted tenant moves to social housing
                end
                house.resident_id = nothing 
            end
            
            if house.resident_id == dead_agent.id
                house.resident_id = nothing # House becomes vacant
            end

            # --- 2. Clear existing listings ---
            # Java: transferAllWealthTo calls removeOffer() unconditionally, and only afterwards
            # does inheritHouse() create new offers. Price and time on market are therefore reset.
            if house.is_for_sale
                house.is_for_sale = false
                delete!(model.market_stats.active_sales_listings, house.id)
                house.months_on_market = 0
                house.listing_price = 0.0 # Reset so that a new price is set when relisted
            end

            if house.is_for_rent
                house.is_for_rent = false
                delete!(model.market_stats.active_rental_listings, house.id)
                house.months_on_rental_market = 0
                house.rental_price = 0.0 
                # A house listed for rent was vacant, so remove it from the vacant count
                model.market_stats.vacant_rentals_by_quality[house.quality] = max(0, model.market_stats.vacant_rentals_by_quality[house.quality] - 1)
            end

            # --- 3. Inheritance and use decision ---
            inherit_house!(beneficiary, house, model)

        end
        # dead_agent.properties_owned is not cleared: that would modify the vector being iterated
        # above, and the deceased agent object is discarded after this function returns.

        # 4. Transfer the remaining financial wealth.
        # The `> 0` test corresponds to Java's Math.max(0.0, bankBalance)
        # (Household.java:546: beneficiary.bankBalance += Math.max(0.0, bankBalance)).
        #   D4_INHERITANCE_OVERPAY = false: the balance is non-negative because payments are capped
        #     at the balance, so the test only excludes a zero balance.
        #   D4_INHERITANCE_OVERPAY = true: the balance can be negative after the discharge loop and the
        #     residual-loan block; the test then passes nothing on to the heir, as in Java.
        if dead_agent.bank_balance > 0
            beneficiary.bank_balance += dead_agent.bank_balance
            dead_agent.bank_balance = 0.0
        end
    end
end

"""
    create_new_household!(model, bin_idx::Int)
Creates a new agent in the specific MONTHLY age bin to refill population deficits.
Implements 'Structural Birth'.
"""
function create_new_household!(model, bin_idx::Int)
    rng = abmrng(model)
    
    # 1. Sample Age (Restricted to Monthly Bin)
    # The bin_idx parameter corresponds to the 1-based index of the monthly age bin.
    monthly_width = model.demographics.monthly_bin_width
    min_age = Float64(model.demographics.raw_bins[1][1])
    
    # Sample uniform age within the specified monthly bin.
    age = min_age + (bin_idx - 1)*monthly_width + rand(rng)*monthly_width

    # 2. Sample Income Percentile then derive income deterministically.
    # Java sequence (Household.java:60-61):
    #   incomePercentile = prng.nextDouble()          ← 1 RNG call
    #   annualIncome = getAnnualGrossEmploymentIncome(age, incomePercentile)  ← 0 RNG calls
    income_percentile = rand(rng)
    annual_income = calculate_income_from_rank(age, income_percentile, model.income_dist;
        spain_essential_nominal_consumption = model.spain_essential_nominal_consumption,
    )

    # 3. Sample Propensity to Save.
    # Java sequence (HouseholdBehaviour.java:52):
    #   propensityToSave = prng.nextDouble()   ← RNG call #3 (after age, after percentile)
    # Must be drawn HERE, before the BTL check, to match Java's constructor RNG order.
    propensity_to_save = rand(rng)

    # 4. Derive Wealth deterministically from income + propensity_to_save.
    # Java (Wealth.java:117):
    #   bankBalance = exp(lnWealthGivenLnIncome.getBinAt(lnIncome)
    #                     .inverseCumulativeProbability(propensityToSave))   ← 0 RNG calls
    # propensityToSave is the CDF percentile; wealth is a deterministic lookup.
    wealth = calculate_wealth_from_rank(annual_income, propensity_to_save, model.wealth_dist)

    # 5. Determine BTL Status.
    # Java (HouseholdBehaviour.java:56):
    #   prng.nextDouble() < BTL_PROBABILITY_MULTIPLIER * BTLProbability.getBinAt(incomePercentile)
    # BTLProbability is loaded from BTLProbabilityPerIncomePercentileBin.csv — a 100-bin
    # empirical table.
    is_btl = false
    btl_coeff = 0.0

    # Use empirical bin upper edges so UK (~100 bins) and Spain (coarser bins)
    # map percentiles consistently from the loaded CSV schema.
    btl_bin_idx = searchsortedfirst(model.btl_prob.bin_uppers, income_percentile)
    if btl_bin_idx > length(model.btl_prob.probabilities)
        btl_bin_idx = length(model.btl_prob.probabilities)
    end
    raw_btl_prob = model.btl_prob.probabilities[btl_bin_idx]

    if rand(rng) < raw_btl_prob * model.params.btl_probability_adjustment
        is_btl = true
        btl_coeff = sample_investor_delta(rng)
    end

    # 6. Create Agent
    # "Born into Social Housing"
    add_agent!(
        model, 
        Float64(age),
        income_percentile,
        wealth,
        annual_income,
        propensity_to_save,  # drawn at step 3 above — not inline rand()
        is_btl,
        btl_coeff,
        nothing,     # Residence (Social Housing)
        nothing,     # Rental Agreement
        Int[],       # Properties Owned
        Mortgage[],  # Mortgages
        ConsumptionObservation(),
        Mortgage[],  # Zombie Debts (Empty — populated only when JAVA_COMPAT_MODE = true)
        SocialHousing,
        0.0,         # Desired Purchase Price (Initial)
        FTB,         # Borrower Type
        0.0,         # realized_disposable_income
        0.0,         # persistent_lti_limit (frozen at bid-time)
        0.0
    )
end

"""
    sample_investor_delta(rng)
Moved here for reuse.
"""
function sample_investor_delta(rng::AbstractRNG)
    r = rand(rng)
    if r < Config.BTL_P_INCOME_DRIVEN
        return Config.BTL_INCOME_DRIVEN_CAP_GAIN_COEFF # Rent Driven
    elseif r < (Config.BTL_P_INCOME_DRIVEN + Config.BTL_P_CAPITAL_DRIVEN)
        return Config.BTL_CAPITAL_DRIVEN_CAP_GAIN_COEFF # Cap Gain Driven
    else
        return Config.BTL_MIX_DRIVEN_CAP_GAIN_COEFF # Mixed
    end
end
