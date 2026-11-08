# src/markets/RentalMarket.jl

# RentalBid struct moved to Types.jl


"""
    update_rental_supply!(model)
Updates the rental supply of buy-to-let investors.
Reference: Carro et al. (2022) Table 12 "Housing decisions as a BTL investor".

Mechanism:
1. Identify vacant properties that are NOT for sale.
2. If vacant, increment time-on-market (implicitly via the loop).
3. Stochastic Rent Reduction:
   - Trigger: Probability ~10.6% per month.
   - Action: Reduce rent by a percentage (Mean ~1.65%).

# === ARCHITECTURAL NOTE: Iteration Strategy ===
# Java Implementation: Iterates over Households → Owned Properties → Filter for Rentals
#   - O(N × M) complexity where N = households, M = avg properties per household
#   - PRNG consumption follows household ID order
#
# Julia Implementation: Iterates directly over active_rental_listings (pre-filtered Set)
#   - O(K) complexity where K = active rental properties
#   - ~85% fewer iterations (avoids scanning owner-occupied and non-rental properties)
#   - PRNG consumption follows house ID order (Set iteration)
#
# Impact: Architectures are mathematically equivalent in EXPECTATION.
# The iteration order difference only affects single-run deterministic replication,
# which is irrelevant for ensemble Monte Carlo validation (n → ∞ convergence).
# This design choice prioritizes computational efficiency over bit-exact replication.
"""
function update_rental_supply!(model)
    # Unpack Parameters (Table 12)
    # Value: 0.1057
    prob_cut = model.params.rent_price_reduction_prob

    # Value: 1.6559 (Mean), 0.7855 (Std). Converted to decimals in Config.jl
    # CRITICAL: Config.jl stores them as decimals (0.016559). Do NOT divide by 100 here.
    mu_cut = model.params.rent_reduction_mean
    sigma_cut = model.params.rent_reduction_std
    
    dist_cut = Normal(mu_cut, sigma_cut)

    for house_id in model.market_stats.active_rental_listings
        house = model.housing_stock[house_id]
        
        # Security Check: Synchronization Safety
        # Ensure the house is actually valid (Vacant, Owned, For Rent).
        # Optimized: Uses persistent O(K) Set, skipping O(N) scan.
        # Cost of safety check is O(1) inside the O(K) loop, so negligible performance impact.
        if house.owner_id !== nothing && house.resident_id === nothing && house.is_for_rent
        
             # Increment Rental Time-on-Market (Tracking active listing duration)
             house.months_on_rental_market += 1

             # FIX: Grace Period for New Listings (Parity with Java)
             # Java's check is `if (getTime() > initialListing)`. 
             # Since Java loop happens monthly, a new listing (Time == Initial) 
             # prevents entering the logic block until the NEXT month (Time > Initial).
             # In Julia, we just incremented to 1. So we must skip if <= 1.
             if house.months_on_rental_market <= 1
                 continue
             end

            # Stochastic Trigger (Table 12)
            # Fixed probability check (No dynamic pressure)
            # If the random check passes, the landlord gets "anxious" and cuts the price.
            if rand(abmrng(model)) < prob_cut
                
                # Calculate Cut
                # Source: "If the property is not rented... reduce the rental price"
                # Updated to Log-Normal Logic (Matches Java and Sales Logic)
                # 1. log_reduction ~ Normal(1.655..., 0.785...)
                log_reduction = rand(abmrng(model), dist_cut)
                
                # 2. Convert to percentage drop
                # e.g., if log_reduction = 1.65 (Mean), drop = e^1.65 / 100 ≈ 5.2%
                percentage_drop = exp(log_reduction) / 100.0
                
                # 3. Cap max reduction at 50% (Match Java Sales logic for safety)
                percentage_drop = min(percentage_drop, 0.5)

                # Initialization Check (Safety Fallback)
                # If a house has no rental price yet, Eq 9 is applied here too.
                # Uses the market's EMA (Exponential Moving Average) plus a level-space markup ratio.
                if house.rental_price <= 0.0
                     # Eq 9: r_s = r_Q * markup_ratio (level-space; see put_on_market! for notation note)
                     # Use Segmented EMA
                     base_rent = model.market_stats.ema_rents_by_quality[house.quality]
                     
                     # Level-space markup ratio from Zoopla empirical distribution (Table 12)
                     markup_ratio = draw_rental_markup(model)
                     
                     # Apply 'Initial rent price mark-up' (Table 12) from empirical data.
                     house.rental_price = base_rent * markup_ratio
                end
                
                # Apply Cut
                # Equation: P_new = P_old * (1 - p_drop)
                reduction_fraction = percentage_drop
                house.rental_price *= (1.0 - reduction_fraction)
                
                # Percentage reduction as described in Carro et al. (2022), Table 12.
                # Chosen decay model: Linear.
                # house.rental_price *= (1.0 - epsilon)
            end
        end 
    end
end

"""
    clear_rental_market!(model)
The core market mechanism implementing a Double Auction with iterations for RENTALS.
Logic adapted from Carro et al. (2022) Section 3.5 to the Rental Market.

Process:
1. Pre-calculate tenant budgets (\$r_d\$).
2. Enter Market Loop (Phases):
   a. MATCHING: Tenants select best rental house (Quality Maximization) <= Budget.
   b. SELECTION: Landlords resolve bids (Rental Gazumping).
   c. CLEANUP: Remove rented houses, return losers to pool.
   d. Repeat until no leases occur.
"""
function clear_rental_market!(model)
    # --- Step 1: Initialization & Inventory ---
    # Identify Supply (Vacant, Owned, AND Flagged for Rent)
    # Collects IDs of all valid rental properties. If none exist, it shuts down early.
    # Uses persistent O(K) set with safety filtering.
    
    # Validation Filter:
    # Ensure we only pick houses that are TRULY vacant and owned.
    # Optimized: Uses persistent O(K) Set.
    # This check is O(K) local cost, far cheaper than O(N) scan.

    available_rentals_ids = filter(h_id -> (
                                        h = model.housing_stock[h_id]; 
                                        h.owner_id !== nothing && h.resident_id === nothing && h.is_for_rent
                                   ), 
                                   model.market_stats.active_rental_listings)
    
    if isempty(available_rentals_ids)
        return
    end

    # --- Step 2: Demand Preparation (Pre-calc Budgets) ---
    # Identify Demand (Homeless Agents OR agents currently in Social Housing)
    # Strictly matches those who need housing.
    
    # Structure: (Agent, Budget)

    active_tenants = Vector{NamedTuple{(:agent, :budget), Tuple{Household, Float64}}}()
    
    # --- PUSH ARCHITECTURE ADAPTER ---
    # Consume Bids from rental_bids_queue (Populated in agent_step!)
    
    for bid in model.market_stats.rental_bids_queue

        if !(bid.agent_id in allids(model))
            continue
        end
        agent = model[bid.agent_id]
        
        # Optimization: Only add valid tenants with positive budget
        if bid.price > 0.0
            push!(active_tenants, (agent = agent, budget = bid.price))
        end
    end
    
    # Clear the queue for the next month
    empty!(model.market_stats.rental_bids_queue)

    # --- Pre-Clearing Statistics Hook ---
    # Captures the raw state of Supply/Demand before matching occurs.
    record_pre_clearing_stats!(model, active_tenants, available_rentals_ids)
    
    # --- Step 3: The Double Auction Loop (Rental) ---
    #
    # Termination conditions (Carro et al. 2022/2023, Section 3.5):
    #   "Both markets clear in the same way, matching bids and offers in a number
    #   of rounds until no match is possible."
    # Rounds continue strictly until one of three conditions is met:
    #   (i)  there are no more bids left          → !isempty(active_tenants)
    #   (ii) there are no more offers left         → !isempty(available_rentals_ids)
    #   (iii) the remaining bids cannot be matched  → inner 'Dead market check' break
    #        (all tenants found no affordable unit in this round)
    #
    while !isempty(active_tenants) && !isempty(available_rentals_ids)
        
        # Build buckets for O(1) selection
        rental_buckets = build_rental_buckets(available_rentals_ids, model)
        
        # Container for Bids: HouseID -> Vector{TenantTuple}

        bids_by_house = Dict{Int, Vector{Any}}()
        
        # A. MATCHING PHASE (Tenants apply for rentals)
        # ---------------------------------------------
        for tenant_tuple in active_tenants
            # Tenants are Maximizers: Best Quality, then Best Price
            # Every active tenant picks their *single best* option from the available pool.
            # This builds a list of "Bids" for each house.
            target_id = select_best_rental_house(
                model, 
                tenant_tuple.agent, 
                tenant_tuple.budget, 
                rental_buckets
            )
            
            if target_id !== nothing
                if !haskey(bids_by_house, target_id)
                    bids_by_house[target_id] = []
                end
                push!(bids_by_house[target_id], tenant_tuple)
            end
        end
        
        # Condition (iii): no tenant could find an affordable unit this round
        # → no further matches are possible; terminate the auction.
        # (Carro et al. 2022/2023, Section 3.5: "no match is possible")
        if isempty(bids_by_house)
            break
        end
        
        # B. SELECTION PHASE (Landlords resolve applications/gazumping)
        # -------------------------------------------------------------
        successful_tenants_ids = Set{Int}()
        rented_houses_ids = Set{Int}()

        # ------------------------------------------------------
        # Java's `HousingMarket.clearMatches()` iterates oversubscribed offers via
        # `Iterator<HousingMarketRecord> = offersPQ.iterator()` on a `PriorityQueue2D`
        # ordered by `PQComparator()` — i.e. PRICE-QUALITY priority order. Both sales
        # and rental markets share this primitive via Java inheritance
        # (HouseRentalMarket.java has no override).
        #
        # Iterating the Dict directly would follow **hash order**, which is neither
        # price-quality nor stable; the order depends on integer-hash bucket layout and
        # is not driven by `abmrng(model)`. It would change which house gets gazumped
        # first when several are oversubscribed, relative to Java.
        #
        # Iteration key: (-quality, rental_price, house_id) — highest quality first
        # (negative for ascending sort), then highest price within quality, then ID
        # tie-break for full determinism.
        sorted_house_ids = sort!(
            collect(keys(bids_by_house)),
            by = hid -> (
                -model.housing_stock[hid].quality,
                model.housing_stock[hid].rental_price,
                hid
            )
        )

        for house_id in sorted_house_ids
            applicants = bids_by_house[house_id]
            house = model.housing_stock[house_id]
            
            # Scenario: Rental Gazumping / Bidding War
            # If multiple tenants want the unit, the rent may increase.
            final_rent = house.rental_price
            
            if length(applicants) > 1
                # 1. Update Rent (Gazumping)
                # Similar to Sales: Rent increases based on N bidders.
                # \$R_{new} = R_{old} \\times \\chi^k\$
                # If a house gets multiple applications, the Rent goes up (Gazumping).
                gazump_rent = resolve_rental_bidding!(model, house, length(applicants))
                
                # Survivors: applicants whose budget still meets the gazumped rent.
                survivors = filter(t -> t.budget >= gazump_rent, applicants)
                
                if !isempty(survivors)
                    # Cases 1 & 2 — Gazump Successful (identical across all implementations)
                    # Case 1: length(survivors) > 1 → rand(survivors); private information rule.
                    # Case 2: length(survivors) == 1 → rand() degenerates to a direct pick.
                    final_rent = gazump_rent
                    winner_tuple = rand(abmrng(model), survivors)
                else
                    # -------------------------------------------------------------------------
                    # Case 3 — Gazumping Overshoot: gazumped rent exceeds ALL submitted bids
                    # -------------------------------------------------------------------------
                    # SITUATION: The geometric bid-up raised the rent above every applicant's
                    # budget (survivors is empty). The landlord failed to extract a higher rent.
                    #
                    # FULL THREE-CASE STRUCTURE for reference:
                    #
                    #   Case 1  length(survivors) > 1  → rand(survivors) at gazump_rent
                    #           Multiple applicants meet the new rent. Private information rule
                    #           (Footnote 21): landlord cannot observe max budgets → uniform random.
                    #           Allocative inefficiency: wealthy tenants may lose to poorer ones,
                    #           forcing them down the quality ladder.
                    #
                    #   Case 2  length(survivors) == 1 → survivors[1] at gazump_rent
                    #           Exactly one applicant meets the raised rent. No ambiguity; direct
                    #           pick. rand() on a single-element collection handles this
                    #           implicitly in the !isempty branch above.
                    #
                    #   Case 3  length(survivors) == 0 → THIS BRANCH (implementations diverge)
                    #           The attempted rent raise collapsed. See below.
                    #
                    # ── AUTHOR + JAVA (JAVA_COMPAT_MODE = true) ──────────────────────────────
                    #
                    #   Author's intent (confirmed Feb 2026): once applications are placed they
                    #   are observable — the submitted bid price (not the private budget ceiling)
                    #   has already been revealed. The real-world analogue is a phone call:
                    #   the landlord rings the highest applicant and asks whether the rental
                    #   still works at their already-stated offer price. Selection is therefore
                    #   deterministic: the highest submitted bid wins, at that bid's price.
                    #
                    #   Java (HousingMarket.java:185-188, clearMatches() — shared base class,
                    #   inherited by HouseRentalMarket):
                    #     // matchedBids is sorted ascending (lowest→highest) by line 177
                    #     winningBid = nBids - 1;   // nBids == size after all drop out → highest last
                    #     salePrice  = matchedBids.get(winningBid).getPrice();
                    #   Java and the author's stated intent are fully consistent on all three cases.
                    #   The rental market inherits this behaviour from the shared HousingMarket
                    #   base class — there is no separate override in HouseRentalMarket.
                    #
                    #   Effect on aggregates (JAVA_COMPAT_MODE = true):
                    #   The achieved rent clears at the highest submitted bid, which lies between
                    #   the original rental ask and the gazumped rent. By the matching constraint
                    #   (select_best_rental_house: rental_price ≤ budget), every applicant's
                    #   budget ≥ rental_price, so winner.budget ≥ rental_price. Case 3
                    #   java_compat rents are therefore AT OR ABOVE the original ask — not below
                    #   it. Relative to the baseline (which clears at rental_price exactly),
                    #   java_compat captures the surplus between rental_price and winner.budget,
                    #   marginally increasing achieved rents and landlord income.
                    #
                    # ── JULIA BASELINE (JAVA_COMPAT_MODE = false, DEFAULT) ───────────────────
                    #
                    #   Transaction Rent → house.rental_price  (the landlord's original ask)
                    #   Winner Selection → rand(applicants)    (uniform random over all original applicants)
                    #
                    #   This is a stricter, unconditional application of two paper rules:
                    #
                    #   1. SELLER'S PRICE RULE (Carro et al. 2022, Section 3.5):
                    #      "Both markets clear in the same way" — the sales market rule applies
                    #      here identically. After a failed rent raise the last valid price
                    #      demanded by the landlord is the original rental ask. All original
                    #      applicants could afford it by construction (matched in the MATCHING
                    #      phase). Settling at rental_price forfeits the surplus between
                    #      rental_price and winner.budget that the java_compat path captures —
                    #      a deliberate conservative choice.
                    #
                    #   2. PRIVATE INFORMATION RULE (Carro et al. 2022, Footnote 21):
                    #      "We choose the winning bid at random, and not simply select the bidder
                    #      with the highest bidding price, to reflect the fact that the maximum
                    #      bidding price is considered private information."
                    #      Applied unconditionally: there is no fallback carve-out. In the
                    #      overshoot branch the landlord still cannot observe applicants' maximum
                    #      rental budgets; ranking by budget would violate the model's market-
                    #      opacity assumption.
                    #
                    #   Known divergence from both Java and the author's stated intent for Case 3.
                    #   This is an intentional design choice: the Julia baseline enforces the
                    #   private-information axiom as an invariant across all branches.
                    #
                    #   Effect on aggregates (JAVA_COMPAT_MODE = false):
                    #   Case 3 rents clear exactly at rental_price. Since winner.budget ≥
                    #   rental_price (matching constraint), the baseline produces Case 3 rents
                    #   ≤ java_compat Case 3 rents. The baseline forfeits the winner.budget −
                    #   rental_price surplus, producing a small downward bias in achieved rents
                    #   and BTL yield numerators relative to java_compat for hot quality bands.
                    # -------------------------------------------------------------------------
                    if Config.D1_RENTAL_COMPAT
                        # Author + Java: highest applicant at their submitted price, deterministic.
                        # Controlled by D1_RENTAL_COMPAT; set it to false to apply D1 to the sales market only.
                        sorted_applicants = sort(applicants, by = t -> t.budget, rev = true)
                        winner_tuple = sorted_applicants[1]
                        final_rent = winner_tuple.budget
                    else
                        # Julia baseline: original rental ask, random winner (stricter private-info invariant)
                        final_rent = house.rental_price
                        winner_tuple = rand(abmrng(model), applicants)
                    end
                end
                
                # Update House Rental Price (Market Adjustment)
                house.rental_price = final_rent
                
                # Execute Lease
                # A lease is signed, and both agent/house are removed from the pool.
                create_lease!(model, house, winner_tuple.agent, final_rent)
                push!(successful_tenants_ids, winner_tuple.agent.id)
                push!(rented_houses_ids, house_id)
                
            else
                # Single applicant
                # Just check budget (Already checked in select_best, this is a safety check).
                # But keep clean logic.
                if applicants[1].budget >= final_rent
                     winner_tuple = applicants[1]
                     create_lease!(model, house, winner_tuple.agent, final_rent)
                     push!(successful_tenants_ids, winner_tuple.agent.id)
                     push!(rented_houses_ids, house_id)
                end
            end
        end
        
        # C. CLEANUP
        # ----------
        filter!(t -> !(t.agent.id in successful_tenants_ids), active_tenants)
        setdiff!(available_rentals_ids, rented_houses_ids)
    end
    
    # Handle Unmatched
    # Tenants remaining in `active_tenants` stay in SocialHousing (Sink State) by definition.
end

"""
    select_best_rental_house(model, agent, budget, available_ids)
Implements the Maximizer logic for Tenants.
Returns house_id or nothing.

Strategy:
1. Filter for Budget (\$Rent \\le r_d\$).
2. Maximize Quality (\$Q\$).
3. Minimize Price (Tie-breaker).
"""
function select_best_rental_house(model, agent, budget, rental_buckets)
    n_qualities = length(rental_buckets)
    
    # Strategy: Tenant Behavior (Maximize Quality -> Minimize Price)
    # 1. Households calculate budget constraint (\$r_d\$) upstream.
    # 2. They filter for affordable houses (Rent <= Budget).
    # 3. They maximize Quality.
    # 4. As a tie-breaker, they minimize Rent.
    #
    # Optimization:
    # We iterate Qualities from High to Low.
    # The first affordable house found in the sorted bucket is the Global Optimum.
    for q in n_qualities:-1:1
        bucket = rental_buckets[q]
        
        if !isempty(bucket)
            # Bucket is sorted by rental_price ascending.
            # The first house is the cheapest in this quality tier.
            
            # Use Loop to handle potential self-renting (unlikely but safe)
            for hid in bucket
                h = model.housing_stock[hid]
                
                # Prevent Self-Renting
                if h.owner_id == agent.id
                    continue
                end

                # Check Budget
                if h.rental_price <= budget
                    # Found the optimal house:
                    # 1. Highest possible Quality (due to outer loop order)
                    # 2. Lowest Price for that Quality (due to bucket sorting)
                    return hid
                end
                
                # Optimization: Since sorted by price, if this one is too expensive, all are.
                if h.rental_price > budget
                    break
                end
            end
        end
    end
    
    return nothing
end

"""
    build_rental_buckets(available_ids, model)
Helper to organize active rental listings into price-sorted quality buckets.
Optimizes the matching phase from O(N) to O(1) per tenant.
"""
function build_rental_buckets(available_ids, model)
    n_qualities = length(model.market_stats.ema_rents_by_quality)

    buckets = [Int[] for _ in 1:n_qualities]
    
    # 1. Bucketize
    for hid in available_ids
        h = model.housing_stock[hid]
        push!(buckets[h.quality], hid)
    end
    
    # 2. Sort by Rental Price (Ascending)
    for q in 1:n_qualities
        # Sort IDs based on the rental price of the house object
        # MATCHING JAVA: Use ID as tie-breaker for deterministic sorting
        sort!(buckets[q], by = hid -> (model.housing_stock[hid].rental_price, hid))
    end
    
    return buckets
end

"""
    resolve_rental_bidding!(model, house, n_bidders)
Calculates the new gazumped rent if multiple tenants bid.
Based on Eq 20 mechanism (Sales) adapted for Rent.
"""
function resolve_rental_bidding!(model, house, n_bidders)
    current_rent = house.rental_price
    
    # 1. Base Case
    if n_bidders <= 1
        return current_rent
    end
    
    # 2. Rescale N (Eq 20 adapted for rental)
    #
    # Rental market uses the same Eq. 20 mechanism as the sales market. The same
    # Java discrete-vs-continuous divergence applies here via the shared HousingMarket
    # base-class clearMatches() logic (HousingMarket.java line ~159).
    #
    if Config.D6_BIDUP_FLOOR
        b = Float64(max(floor(Int, log10(n_bidders)), 1))
    else
        b = max(log10(n_bidders), 1.0)
    end
    
    # 3. Probability of Price Increase
    # Using same days_under_offer parameter or rent specific?
    # Usually fast moving. We assume similar urgency.
    # Determines probability p derived from days_under_offer parameters.
    days_offer = hasproperty(model.params, :days_under_offer) ? model.params.days_under_offer : 3.0
    prob_new_bid = days_offer / 30.0 
    
    # 4. Geometric distribution for steps (k)
    # Draws a number of price increments k from a Geometric distribution. Models "bidding wars".
    p_success = (1.0 - prob_new_bid)^(b - 1.0)
    p_success = clamp(p_success, 1e-6, 1.0)
    
    dist_geom = Geometric(p_success)
    k = rand(abmrng(model), dist_geom)
    
    # 5. Calculate New Rent
    # R_new = R_old * (chi)^k
    # Where chi is the bid_up_factor (e.g. 1.05 or 5% increase per step).
    # chi = bid_up_factor (e.g. 1.05)
    chi = model.params.bid_up_factor
    
    new_rent = current_rent * (chi^k)
    
    return new_rent
end

"""
    calc_rental_budget(agent, model)
Calculates the maximum rent an agent is willing/able to pay (\$r_d\$).
Eq 5: \$r_d = \\min(\\mu \\cdot y^{\\nu}, r_{max})\$
where \$r_{max}\$ is strictly affordability (e.g. 40% of income).
"""
# calc_rental_budget moved to HouseholdBehavior.jl



"""
    create_lease!(model, house, tenant, rent)
Helper to update state to reflect a new tenancy.
"""
function create_lease!(model, house, tenant, rent)
    # 1. Link House to Tenant
    house.resident_id = tenant.id
    tenant.residence_id = house.id
    
    # 2. Create Agreement
    # Duration: Uniformly random between min/max (Table 12: 12-24 months)
    duration = rand(abmrng(model), model.params.tenancy_length_min:model.params.tenancy_length_max)
    
    agreement = RentalAgreement(
        house.id, 
        rent, 
        duration, 
        duration # Start with full duration remaining
    )
    tenant.rental_agreement = agreement
    
    # 3. Market State Update
    # If the property was for sale, it is now withdrawn because it is no longer vacant.
    # (Matches "Sold Vacant" rule: You cannot sell with a sitting tenant).
    house.is_for_sale = false
    # Also clear the rent flag, as it is no longer seeking a tenant.
    house.is_for_rent = false
    delete!(model.market_stats.active_rental_listings, house.id)
    
    # Also clear the sales flag (Withdrawal from Sales Market)
    # BLIND DELETE: Ensure it is removed from sales set regardless of flag state to prevent ghosts.
    house.is_for_sale = false
    delete!(model.market_stats.active_sales_listings, house.id)
    
    
    
    # Record Transfer
    model.market_stats.rental_flow_temp += 1
    
    # Update Stats Incremental Counters
    model.market_stats.vacant_rentals_by_quality[house.quality] -= 1
    model.market_stats.occupied_rentals_by_quality[house.quality] += 1
    
    # Record Price for Segmented EMA (Market Information System)
    push!(model.market_stats.current_rents_by_quality[house.quality], rent)
    push!(model.market_stats.current_rental_mom_by_quality[house.quality], house.months_on_rental_market)
    
    # Update Status
    tenant.tenure_status = Renter
end

"""
    draw_rental_markup(model)
Returns a level-space markup ratio for the RENTAL market (Eq 9).
The returned value is exp(η_paper) — a multiplicative ratio ∈ [0.5, 2.0].
Reference: Carro et al. (2022) Table 12 "Initial rent price mark-up".
Paper notation: ln(r_s) = ln(r_Q) + η. Implementation: r_s = r_Q × markup_ratio.
The data file `InitialRentMarkUpDist.csv` contains ratio bins [0.5, 2.0], not log bins.


"""
function draw_rental_markup(model)
    # Use Empirical Distribution from Zoopla/ONS
    return sample_markup(abmrng(model), model.rent_markup_dist)
end
