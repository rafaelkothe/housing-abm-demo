# src/markets/HousingMarket.jl
#
# Sales market: bid matching, price bidding, clearing and settlement.
#
# Contents:
#   - build_listings_buckets: groups active sale listings into price-sorted quality buckets.
#   - clear_sales_market!: multi-round double auction that matches queued buyer bids to listings.
#   - select_best_house: chooses the target listing for one buyer (quality-first for
#     owner-occupiers, yield-first for buy-to-let investors).
#   - resolve_price_bidding!: price raise when several buyers bid for the same house.
#   - check_bank_approval: affordability test of a price against cash plus the maximum loan.
#   - execute_transaction!: settlement of a matched sale (mortgage origination, seller payoff,
#     ownership transfer, transaction log).
#   - update_for_sale_supply!: monthly price revision and withdrawal of existing sale listings,
#     and re-listing of surplus vacant properties.
#   - put_on_market!, draw_sales_markup: creation of a sale listing and its initial price.
#
# Bids are produced by the household behaviour code and queued in `market_stats.bids_queue`;
# the `Bid` type is defined in Types.jl.

"""
    build_listings_buckets(available_ids, model)

Group the active sale listings `available_ids` by house quality.

Returns a vector with one bucket per quality level (index = quality). Each bucket holds house IDs
sorted by ascending listing price, with the house ID as tie-breaker so that the ordering is
deterministic. Buyers can then inspect only the cheapest entries of each quality tier instead of
scanning all listings.
"""
function build_listings_buckets(available_ids, model)
    n_qualities = length(model.market_stats.ema_prices_by_quality)
    buckets = [Int[] for _ in 1:n_qualities]
    
    # Bucketize by quality
    for hid in available_ids
        h = model.housing_stock[hid]
        push!(buckets[h.quality], hid)
    end
    
    # Sort each bucket by ascending listing price. The house ID is the tie-breaker, mirroring the
    # deterministic ordering of the Java model's PriorityQueue2D.
    for q in 1:n_qualities
        sort!(buckets[q], by = hid -> (model.housing_stock[hid].listing_price, hid))
    end
    
    return buckets
end

"""
    clear_sales_market!(model)

Clear the sales market with a multi-round double auction (Carro et al. 2022, Section 3.5).

Buyers' bids are read from `model.market_stats.bids_queue` and the available listings from
`model.market_stats.active_sales_listings`. Mutates the model through `execute_transaction!` for
every completed sale, records pre-clearing supply and demand statistics, and always empties the
bid queue before returning.

Process:
1. Convert queued bids into a list of active buyers, dropping invalid bids.
2. Repeat the following rounds while buyers and listings remain:
   a. Matching: each buyer selects its preferred listing within budget (see `select_best_house`).
   b. Selection: for each listing with bids, the seller resolves competing bids (price bidding).
   c. Cleanup: buyers whose purchase was settled or rejected, and sold houses, leave the pool.
   d. The auction stops when no buyer can find an affordable listing.
"""
function clear_sales_market!(model)
    # --- Inventory ---
    # Work on a shallow copy of the active listings: sold houses are removed from the copy during
    # the auction rounds while the persistent set in MarketStats is left untouched.
    available_houses_ids = copy(model.market_stats.active_sales_listings)

    if isempty(available_houses_ids)
        # No supply this step: discard queued bids so they do not carry over to the next step.
        empty!(model.market_stats.bids_queue)
        # Record zero supply/demand statistics.
        record_pre_clearing_stats!(model, [], [])
        return
    end

    # --- Demand preparation ---
    # Each active buyer is (agent, budget, is_btl, desired_down_payment, p_max), where `budget` is
    # the bid price. Bids are queued by the household behaviour code during the agent step.
    active_buyers = Vector{NamedTuple{(:agent, :budget, :is_btl, :desired_down_payment, :p_max), Tuple{Household, Float64, Bool, Float64, Float64}}}()
    
    if isempty(model.market_stats.bids_queue)
         # No demand: record zero demand statistics.
         record_pre_clearing_stats!(model, [], available_houses_ids)
         return
    end

    for bid in model.market_stats.bids_queue
        # Skip bids of agents that no longer exist (for example after death or removal).
        if !Agents.hasid(model, bid.agent_id)
            continue
        end
        
        agent = model[bid.agent_id]
        
        # Drop bids that clearing cannot process: insolvent bidders and malformed prices or
        # down payments. Valid bids are passed on unchanged.
        if agent.bank_balance < 0.0
            continue
        end
        if !isfinite(bid.price) || bid.price <= 0.0
            continue
        end
        if !isnan(bid.desired_down_payment)
            if !isfinite(bid.desired_down_payment) || bid.desired_down_payment < 0.0
                continue
            end
        end

        # Derive the bid type from agent state (equivalent to the Java model's BTLBid flag).
        # Buy-to-let purchase: the agent is a BTL investor and already owns a home.
        # Owner-occupier purchase (including the first home of a BTL investor): otherwise.
        is_btl = agent.is_btl_investor && agent.tenure_status == OwnerOccupier
        
        push!(active_buyers, (agent = agent, budget = bid.price, is_btl = is_btl, desired_down_payment = bid.desired_down_payment, p_max = bid.p_max))
    end

    # The queued bids have been converted into active buyers, so the queue can be emptied.
    empty!(model.market_stats.bids_queue)
    
    # Record supply and demand statistics before any trade (as in the Java model).
    record_pre_clearing_stats!(model, active_buyers, available_houses_ids)
    
    # --- Double auction loop ---
    # Matches buyers to sellers over multiple rounds.
    #
    # Termination conditions (Carro et al. 2022/2023, Section 3.5):
    #   "Both markets clear in the same way, matching bids and offers in a number
    #   of rounds until no match is possible."
    # Rounds continue until one of three conditions is met:
    #   (i)   there are no more bids left          -> `isempty(active_buyers)`
    #   (ii)  there are no more offers left        -> `isempty(available_houses_ids)`
    #   (iii) the remaining bids cannot be matched -> the `break` below when no buyer
    #         finds an affordable house in a round
    #
    # No hard limit on the number of rounds is imposed, in line with the paper's stated
    # termination conditions.
    while !isempty(active_buyers) && !isempty(available_houses_ids)
        
        # Rebuild the sorted buckets every round: listing prices can change during selection.
        listings_buckets = build_listings_buckets(available_houses_ids, model)
        
        # House ID -> buyers bidding for that house in this round.
        bids_by_house = Dict{Int, Vector{Any}}()
        
        # A. Matching phase: buyers place bids
        # -------------------------------------
        for buyer_tuple in active_buyers
            # Every active buyer picks a single preferred house (the rule depends on the bid type)
            # and places a bid on it.
            target_id = select_best_house(
                model, 
                buyer_tuple.agent, 
                buyer_tuple.budget, 
                buyer_tuple.is_btl, 
                listings_buckets
            )
            
            if target_id !== nothing
                if !haskey(bids_by_house, target_id)
                    bids_by_house[target_id] = []
                end
                push!(bids_by_house[target_id], buyer_tuple)
            end
        end
        
        # Condition (iii): no buyer could find an affordable house this round, so no further
        # matches are possible and the auction ends.
        if isempty(bids_by_house)
            break
        end
        
        # B. Selection phase: sellers resolve bids
        # -----------------------------------------
        successful_buyers_ids = Set{Int}()
        sold_houses_ids = Set{Int}()
        rejected_buyers_ids = Set{Int}()

        # Process oversubscribed houses in price-quality priority order (highest quality first,
        # then lowest listing price, then house ID). This mirrors the Java model's
        # `HousingMarket.clearMatches()`, which iterates offers of a `PriorityQueue2D`, and makes
        # the order in which competing bids are resolved independent of hash order.
        sorted_house_ids = sort!(
            collect(keys(bids_by_house)),
            by = hid -> (
                -model.housing_stock[hid].quality,
                model.housing_stock[hid].listing_price,
                hid
            )
        )

        for house_id in sorted_house_ids
            bidders = bids_by_house[house_id]
            house = model.housing_stock[house_id]
            
            # Price bidding when several buyers want the same house
            final_price = house.listing_price
            
            if length(bidders) > 1
                # The seller raises the price (Carro et al.: "Seller increases the price...");
                # bidders whose budget no longer covers the raised price drop out.
                
                # Number of price raises is drawn from a geometric distribution that includes 0.
                gazump_price = resolve_price_bidding!(model, house, length(bidders))
                
                # Survivors: bidders whose budget still meets the gazumped price.
                survivors = filter(b -> b.budget >= gazump_price, bidders)
                
                if !isempty(survivors)
                    # At least one bidder can pay the raised price: one of them is drawn uniformly at
                    # random (a single survivor is picked directly) and pays the raised price. The
                    # random draw reflects that the seller cannot observe maximum budgets (Carro et
                    # al. 2022, Footnote 21).
                    final_price = gazump_price
                    winner_tuple = rand(abmrng(model), survivors)
                else
                    # The raised price exceeds every bidder's budget, so nobody survives.
                    #
                    # D1_GAZUMPING_COMPAT = true (default; Java model behaviour,
                    # HousingMarket.clearMatches()):
                    #   the highest bidder wins and pays their own submitted bid price. Submitted
                    #   bids are observable, so the seller can fall back to the highest of them.
                    #
                    # D1_GAZUMPING_COMPAT = false (paper behaviour):
                    #   the sale falls back to the original listing price and the winner is drawn
                    #   uniformly at random among all bidders, as in the paper's rules that a sale
                    #   to a bidder is completed at the price demanded by the seller and that the
                    #   winning bid is chosen at random (Carro et al. 2022, Section 3.5 and
                    #   Footnote 21). Every bidder's budget is at least the listing price, because
                    #   matching only considers houses priced within budget.
                    if Config.D1_GAZUMPING_COMPAT
                        # Deterministic single-pass scan; `argmax` returns the bidder tuple itself.
                        winner_tuple = argmax(b -> b.budget, bidders)
                        final_price  = winner_tuple.budget
                    else
                        final_price = house.listing_price
                        winner_tuple = rand(abmrng(model), bidders)
                    end
                end

                # Settle the sale. On success the listing price is updated to the price paid.
                ok = execute_transaction!(model, house_id, winner_tuple.agent.id, final_price, winner_tuple.desired_down_payment, winner_tuple.p_max, winner_tuple.is_btl)
                if ok
                    house.listing_price = final_price
                    push!(successful_buyers_ids, winner_tuple.agent.id)
                    push!(sold_houses_ids, house_id)
                else
                    push!(rejected_buyers_ids, winner_tuple.agent.id)
                end
            else
                # Single bidder: the budget is still checked against the current price.
                if bidders[1].budget >= final_price
                    winner_tuple = bidders[1]
                    ok = execute_transaction!(model, house_id, winner_tuple.agent.id, final_price, winner_tuple.desired_down_payment, winner_tuple.p_max, winner_tuple.is_btl)
                    if ok
                        push!(successful_buyers_ids, winner_tuple.agent.id)
                        push!(sold_houses_ids, house_id)
                    else
                        push!(rejected_buyers_ids, winner_tuple.agent.id)
                    end
                end
            end
        end
        
        # C. Cleanup: prepare the next round
        # -----------------------------------
        # Buyers whose purchase was settled or rejected leave the pool; other bidders stay and
        # bid again in the next round.
        filter!(active_buyers) do b
            !(b.agent.id in successful_buyers_ids) &&
            !(b.agent.id in rejected_buyers_ids)
        end
        
        # Sold houses are no longer available.
        setdiff!(available_houses_ids, sold_houses_ids)
    end
    
    # Always drain the bid queue: bids that were not matched in this clearing must not carry over
    # to the next step, when the bidders' finances may have changed. Buyers who are still
    # interested bid again next step.
    empty!(model.market_stats.bids_queue)
end

"""
    select_best_house(model, agent, budget, is_btl, listings_buckets)

Choose the listing a buyer bids for, using the price-sorted quality buckets from
`build_listings_buckets`. Returns the house ID, or `nothing` if no listing is affordable.

- Buy-to-let buyers (`is_btl = true`) maximise expected rental yield (Carro et al. 2022, Eq. 12).
- Other buyers maximise quality and then minimise price (Eq. 11).

Only listings with `listing_price <= budget` are considered. The treatment of houses owned by the
buyer depends on `Config.D2_SELF_OWNERSHIP_GUARD`: when it is set, a bid whose selected house is
owned by the buyer is dropped; otherwise such houses are skipped and the next candidate is used.
"""
function select_best_house(model, agent, budget, is_btl, listings_buckets)
    best_house_id = nothing
    n_qualities = length(listings_buckets)
    
    if is_btl
        # BTL buyers maximise expected rental yield (Carro et al. 2022, Eq. 12):
        # yield = E[rent] / price. Within a quality tier E[rent] is constant, so the best yield
        # in a tier is the lowest price; buckets are sorted by ascending price, so the cheapest
        # eligible house is the best candidate of each tier.
        
        best_yield = -1.0
        
        # Tier order matters for ties. Tiers are scanned from the highest quality down and the
        # comparison `yld > best_yield` is strict, so on an exact yield tie the higher quality
        # tier is kept. Exact equality across tiers is a floating-point coincidence; preferring
        # the higher quality gives a deterministic rule. The Java model's PYComparator breaks
        # ties by price ascending, then yield descending, then house ID
        # (HousingMarketRecord.java), so on an exact tie it may choose a different house.
        for q in n_qualities:-1:1
            bucket = listings_buckets[q]
            if !isempty(bucket)
                # Within a tier E[Rent] and occupancy are constant, so maximum yield means minimum
                # price: only the cheapest eligible house of the tier needs to be evaluated.
                #
                # Self-ownership guard (BTL branch). The Java model first takes the best-yield
                # offer over all houses (HouseSaleMarket.getBestOffer(), offersPY.peek(bid)),
                # without an ownership check, and then drops the bid if the buyer owns that house
                # (HousingMarket.matchBidsWithOffers()).
                #   D2_SELF_OWNERSHIP_GUARD = true:  the cheapest house of the tier is the
                #     tier candidate whoever owns it; the ownership test follows after the loop.
                #   D2_SELF_OWNERSHIP_GUARD = false: self-owned houses are skipped and the
                #     cheapest house of the tier owned by someone else is the candidate, so an
                #     investor who owns the cheapest listing can still buy the next one.
                target_hid = nothing

                if Config.D2_SELF_OWNERSHIP_GUARD
                    # Guard on: take the cheapest house in the tier as the candidate regardless of
                    # ownership; the ownership check is made after the loop over tiers.
                    target_hid = bucket[1]
                else
                    # Skip the buyer's own houses and use the cheapest remaining house in the tier.
                    for hid in bucket
                        if model.housing_stock[hid].owner_id != agent.id
                            target_hid = hid
                            break
                        end
                    end
                end
                
                if target_hid !== nothing
                    h = model.housing_stock[target_hid]
                    
                    if h.listing_price <= budget
                        # Expected gross yield, as in the Java model (HouseOfferRecord.
                        # recalculateHouseSpecificYield): ema_rent[q] * 12 * occupancy[q] / price.
                        occ_q  = model.market_stats.occupancy_rate_by_quality[h.quality]
                        r_exp  = model.market_stats.ema_rents_by_quality[h.quality]
                        price  = h.listing_price > 0 ? h.listing_price : 1.0
                        yld    = r_exp * 12.0 * occ_q / price
                        
                        if yld > best_yield
                            best_yield = yld
                            best_house_id = target_hid
                        end
                    end
                end
            end
        end

        # Self-ownership guard, second step. With D2_SELF_OWNERSHIP_GUARD the tier candidates above
        # are chosen without regard to ownership. As in the Java model (matchBidsWithOffers()), if
        # the best-yield house overall is owned by the buyer, the whole bid is dropped with no
        # fallback to the next-best candidate. Without the guard, self-owned houses were already
        # skipped during the search, so this check is not reached.
        if Config.D2_SELF_OWNERSHIP_GUARD && best_house_id !== nothing &&
                model.housing_stock[best_house_id].owner_id == agent.id
            return nothing
        end

    else
        # Non-BTL buyers filter by budget and then maximise quality (Eq. 11), with ties
        # resolved in favour of the lower price.
        #
        # Qualities are scanned from highest to lowest, so the first house found within budget
        # has the highest affordable quality and, because buckets are sorted by price, the lowest
        # price within that quality: it is the buyer's optimum.
        
        for q in n_qualities:-1:1
            bucket = listings_buckets[q]
            if !isempty(bucket)
                # The bucket is sorted by ascending price, so entries are examined from cheapest upwards;
                # normally the first one is chosen, unless the buyer owns it.
                for hid in bucket
                    h = model.housing_stock[hid]

                    # Ascending price order: once over budget all remaining entries are too.
                    if h.listing_price > budget
                        break
                    end

                    # Self-ownership guard (owner-occupier branch). `h` is within budget. In the Java model
                    # the best offer is returned without an ownership check and a bid on the buyer's own
                    # house is dropped afterwards (HousingMarket.matchBidsWithOffers()).
                    #   D2_SELF_OWNERSHIP_GUARD = true:  return nothing, so the bid is dropped without
                    #     searching for a second-best house (Java behaviour).
                    #   D2_SELF_OWNERSHIP_GUARD = false: skip the buyer's own house and continue with the next
                    #     candidate in this bucket or a lower quality tier, since an "available" house
                    #     excludes the buyer's own house.
                    if h.owner_id == agent.id
                        if Config.D2_SELF_OWNERSHIP_GUARD
                            return nothing  # Java: bid silently dropped, no second-best search
                        else
                            continue        # Paper: skip self-owned, find next candidate
                        end
                    end

                    return hid  # affordable and not self-owned
                end
            end
        end
    end
    
    return best_house_id
end

"""
    check_bank_approval(model, agent, price)

Return `true` if the buyer's cash balance plus the maximum loan the bank offers
(`evaluate_credit`) covers `price`.
"""
function check_bank_approval(model, agent, price)
    # Maximum loan the bank offers for this purchase.
    max_loan = evaluate_credit(model.bank, agent, price, model)
    # The buyer must cover the part of the price that the loan does not.
    needed = max(0.0, price - agent.bank_balance)
    return needed <= max_loan
end

"""
    resolve_price_bidding!(model, house, n_bidders)

Return the price at which `house` is offered after the seller's bid-ups when `n_bidders` buyers
compete for it (Carro et al. 2022, Eqs. 18-20).

The listing price is returned unchanged for fewer than two bidders. Otherwise the number of bid-ups
`k` is drawn from a geometric distribution (using the model's random number generator) and the
result is `listing_price * bid_up_factor^k`. The house itself is not modified.
"""
function resolve_price_bidding!(model, house, n_bidders)
    current_price = house.listing_price
    
    # Fewer than two bidders: no competition, the price is unchanged.
    if n_bidders <= 1
        return current_price
    end
    
    # Rescaled number of bidders b (Eq. 20 and Footnote 45).
    #
    # D6_BIDUP_FLOOR = false (paper, default): b = max(log10(n), 1.0), a continuous
    #   logarithm, so competition intensity grows smoothly with the number of bids.
    # D6_BIDUP_FLOOR = true (Java model, HousingMarket.clearMatches()): the Java code computes
    #   `Math.max((int)(Math.log10(nBids)), 1)`, truncating log10 to an integer before taking
    #   the maximum, so b = max(floor(log10(n)), 1). For 2 <= n <= 99 this gives b = 1, hence
    #   p_success = 1 and no bid-up; both formulas coincide for n <= 10.
    if Config.D6_BIDUP_FLOOR
        b = Float64(max(floor(Int, log10(n_bidders)), 1))
    else
        b = max(log10(n_bidders), 1.0)
    end
    
    # Probability of success (Eq. 20): the "days under offer" parameter (Table 14) is
    # normalised by 30 days to give the probability that a further bid arrives. The more
    # bidders there are (larger b), the lower the probability that the price does not rise.
    days_offer = hasproperty(model.params, :days_under_offer) ? model.params.days_under_offer : 3.0
    prob_new_bid = days_offer / 30.0 # 0.1 if days=3 

    
    p_success = (1.0 - prob_new_bid)^(b - 1.0)
    p_success = clamp(p_success, 1e-6, 1.0)
    
    # Number of bid-ups k (Eq. 19) drawn from a geometric distribution, so k = 0 has positive
    # probability.
    dist = Geometric(p_success)
    n_bid_ups = rand(abmrng(model), dist)
    
    # New price (Eq. 18): the price rises by the bid-up factor (Table 14) for each of the k
    # bid-ups, P_new = P_old * bid_up_factor^k.
    new_price = current_price * (model.params.bid_up_factor ^ n_bid_ups)
    
    return new_price
end

"""
    _resolve_settlement_financing(price, max_loan, cash, desired)

Split a purchase price into a down payment and a mortgage principal.

`max_loan` is the largest loan the bank offers, `cash` the buyer's available balance and `desired`
the down payment the buyer would like to make. The loan is capped at the price, which fixes a
minimum deposit; the deposit is the larger of that minimum and the desired amount (limited to the
cash available and to the price).

Returns `nothing` if any input is non-finite or out of range, or if `cash` is below the minimum
deposit. Otherwise returns `(down_payment, principal)`.
"""
function _resolve_settlement_financing(
    price::Float64,
    max_loan::Float64,
    cash::Float64,
    desired::Float64,
)
    if !(isfinite(price) && price > 0.0 &&
         isfinite(max_loan) && max_loan >= 0.0 &&
         isfinite(cash) && cash >= 0.0 &&
         isfinite(desired) && desired >= 0.0)
        return nothing
    end

    loan_cap = min(max_loan, price)
    minimum_deposit = price - loan_cap
    cash < minimum_deposit && return nothing

    wanted = clamp(desired, 0.0, min(cash, price))
    deposit = max(minimum_deposit, wanted)
    principal = price - deposit

    return (down_payment = deposit, principal = principal)
end

"""
    execute_transaction!(model, house_id, buyer_id, price,
                         bid_desired_down_payment=NaN, bid_p_max=NaN, bid_is_btl_purchase=nothing)

Settle the sale of `house_id` to `buyer_id` at `price`. Returns `true` if the sale was completed and
`false` if it was rejected.

Rejection happens before any state is changed, when the price, house, buyer or seller references are
invalid, the house is not for sale, the buyer owns it or already holds a mortgage on it, the bid's
purchase type no longer matches the buyer's current state (`bid_is_btl_purchase`), the credit check
or the down-payment/principal split fails, or the contract terms are invalid.

`bid_desired_down_payment` is the down payment fixed at bid time (`NaN` if it is to be computed here)
and `bid_p_max` is the bid's maximum price, which is only stored in the transaction record.

On success the function mutates the model: it repays the seller's mortgage on the house and credits
the seller with the net proceeds, debits the buyer's down payment, originates and registers a
mortgage for the buyer if the purchase is financed, evicts any tenant, updates tenure, residence,
rental and sale listings and market statistics, appends a `Transaction` to `model.transaction_log`
and moves the house into the buyer's portfolio.
"""
function execute_transaction!(model, house_id, buyer_id, price, bid_desired_down_payment::Float64=NaN, bid_p_max::Float64=NaN, bid_is_btl_purchase::Union{Nothing,Bool}=nothing)
    if !isfinite(price) || price <= 0.0
        return false
    end
    if !(1 <= house_id <= length(model.housing_stock))
        return false
    end
    if !Agents.hasid(model, buyer_id)
        return false
    end

    house = model.housing_stock[house_id]
    buyer = model[buyer_id]
    if !house.is_for_sale
        return false
    end
    if house.owner_id !== nothing && !Agents.hasid(model, house.owner_id)
        println("[SETTLEMENT REJECT] invalid seller reference for house $(house_id)")
        return false
    end
    if house.owner_id == buyer_id
        return false
    end
    if buyer.tenure_status == Renter && buyer.residence_id !== nothing
        old_rental_id = buyer.residence_id
        if !(1 <= old_rental_id <= length(model.housing_stock))
            println("[SETTLEMENT REJECT] invalid renter residence reference for buyer $(buyer_id)")
            return false
        end
    end
    if any(m -> m.house_id == house_id, buyer.mortgages_held)
        return false
    end

    current_is_btl_purchase = buyer.is_btl_investor && buyer.tenure_status == OwnerOccupier
    if bid_is_btl_purchase !== nothing && bid_is_btl_purchase != current_is_btl_purchase
        # Reject a bid whose purchase type (owner-occupier or buy-to-let) no longer matches the
        # buyer's state, so that bid-time and settlement-time classification agree.
        return false
    end
    is_btl_purchase = bid_is_btl_purchase === nothing ? current_is_btl_purchase : bid_is_btl_purchase
    origination_type = is_btl_purchase ? BTL : (buyer.borrower_type == FTB ? FTB : HM)

    # A. Loan details
    max_loan = evaluate_credit(model.bank, buyer, price, model)
    if !isfinite(max_loan) || max_loan < 0.0
        return false
    end

    # Desired down payment. A bid may carry the down payment the buyer chose at bid time; if it
    # is NaN, the down payment is computed here from the sale price. `Config.D19_MODE`, applied
    # when bids are submitted (HouseholdBehavior.jl), decides which bids carry a value:
    #   :OFF   all bids carry NaN, so every buyer's down payment is computed here.
    #   :ON    all bids carry a value, which is reused for every buyer (Java model: Household.java
    #          fixes the desired down payment at bid time and passes it to requestLoan).
    #   :PAPER (default) owner-occupier and first-time-buyer bids carry a value; buy-to-let bids
    #          carry NaN, so their down payment is computed here once the bid has succeeded
    #          (Carro et al. 2022, Section 3).
    # The `isnan` test below therefore covers all three modes.
    #
    # In every mode `max_loan` is computed against the sale price, not the bid price, as in the
    # Java model's requestApproval. The stored value is only the desired down payment; the bank's
    # LTV/LTI/DSTI/ICR limits still apply, and the final (down_payment, principal) pair is bounded
    # in `_resolve_settlement_financing`.
    desired = if !isnan(bid_desired_down_payment)
        bid_desired_down_payment
    else
        calculate_down_payment(buyer, price, model, max_loan, is_btl_purchase)
    end

    financing = _resolve_settlement_financing(price, max_loan, buyer.bank_balance, desired)
    financing === nothing && return false
    down_payment = financing.down_payment
    final_loan_principal = financing.principal

    # Compute the contract terms before any settlement state is changed.
    tx_monthly_payment = 0.0
    tx_term_months = 0
    if final_loan_principal > 0.0
        # Mortgage term, computed before the monthly payment because the annuity depends on it.
        # Java parity: Bank.getNPayments(isHome, age) and Bank.getMonthlyPaymentFactor(isHome, age).
        # The age limit and the full term are the values resolved for this model run.
        bank_age_limit = model.bank_age_limit
        max_term_months = model.mortgage_duration_years * 12
        term_months = 0

        # With `model.spain_btl_repayment_mode` set, buy-to-let loans are treated as home loans:
        # they are repaid as annuities and take the owner-occupier term rule below. This follows
        # the Spanish Java variant, where Bank.requestApproval sets `isHome = true` for buy-to-let
        # loans when interest-only buy-to-let mortgages are switched off.
        btl_routed_as_home = model.spain_btl_repayment_mode

        # `model.spain_btl_paper_maturity` separates the term rule from that routing: when it is set
        # together with `spain_btl_repayment_mode`, buy-to-let loans get the flat full term (Carro
        # et al. 2022, Section 3.4) but are still repaid as annuities (see below). Underwriting
        # limits are applied in Bank.jl.
        btl_term_uses_age_ladder = btl_routed_as_home && !model.spain_btl_paper_maturity

        if is_btl_purchase && !btl_term_uses_age_ladder
            # Buy-to-let with the paper's rules: full flat term.
            term_months = max_term_months
        else
            # Owner-occupier loans, and buy-to-let loans routed as home loans: term capped by the
            # time remaining until the bank's age limit.
            # Java: (int)((BANK_AGE_LIMIT - age) * MONTHS_IN_YEAR), i.e. floor truncation.
            months_to_retirement = floor(Int, (bank_age_limit - buyer.age) * 12)
            term_months = min(max_term_months, months_to_retirement)
        end

        # Ensure a positive term.
        term_months = max(1, term_months)

        # Monthly payment for the mortgage record, using the age-adjusted term.
        #
        # Default (paper): buy-to-let loans are interest-only and owner-occupier loans are annuities.
        #   "The only mortgage product that the bank offers to BTL borrowers is a
        #    fixed-rate interest-only mortgage with a fixed maturity of 25 years."
        #   (Carro et al. 2022, Section 3.4)
        #
        # With `btl_routed_as_home` (Spanish variant): all mortgages are annuities, as in the
        #   Java variant's Bank.requestApproval, where the payment is
        #   `principal * getMonthlyPaymentFactor(true, age)`. The Spanish paper states: "As opposed
        #   to the original model, we do not consider interest-only mortgages for buy-to-let
        #   investors."
        monthly_payment = 0.0

        if is_btl_purchase && !btl_routed_as_home
            # Interest-only: payment = principal * monthly rate.
            monthly_rate = model.bank.current_mortgage_rate / 12.0
            monthly_payment = final_loan_principal * monthly_rate
        else
            # Annuity over the age-adjusted term. Passing `term_months / 12.0` replicates Java's
            # getNPayments truncation: buyers far enough from the age limit get the full
            # configured term, older buyers a shorter one.
            monthly_payment = annuity_payment(
                final_loan_principal,
                model.bank.current_mortgage_rate,
                term_months / 12.0   # age-adjusted, not Config.MORTGAGE_DURATION_YEARS
            )
        end

        if !isfinite(monthly_payment) || monthly_payment < 0.0 || !isfinite(term_months) || term_months < 1
            println("[SETTLEMENT REJECT] invalid contract terms for buyer $(buyer_id)")
            return false
        end

        tx_monthly_payment = monthly_payment
        tx_term_months = term_months
    end
    
    # Store previous owner ID for portfolio update later
    previous_owner_id = house.owner_id
    # Snapshot seller occupancy before any eviction/buyer mutations in this transaction.
    seller_was_resident = (
        previous_owner_id !== nothing &&
        house.resident_id !== nothing &&
        house.resident_id == previous_owner_id
    )
    house_had_tenant = (
        house.resident_id !== nothing &&
        house.resident_id != previous_owner_id
    )

    # Seller's remaining principal on this house, recorded in the transaction log. Declared at
    # function scope so that it is available when the transaction is logged.
    seller_debt_for_tx = 0.0

    # Contract identifier for the transaction log (0 for cash purchases)
    tx_mortgage_id = 0
    
    # --- Rental clean-up ---
    # A house that was also offered for rent (a vacant rental, for example an investor selling a
    # vacant property) is removed from the rental listings and statistics.
    if house.is_for_rent
         house.is_for_rent = false # Clear flag
         if house.id in model.market_stats.active_rental_listings
             delete!(model.market_stats.active_rental_listings, house.id)
             model.market_stats.vacant_rentals_by_quality[house.quality] -= 1
         end
    end
    
    # 1. Handle Seller
    if house.owner_id !== nothing
        seller = model[house.owner_id]
        
        # Find the seller's mortgage on this specific house (linear scan over the seller's mortgages).
        m_idx = findfirst(m -> m.house_id == house_id, seller.mortgages_held)
    
        debt_to_settle = 0.0
        if m_idx !== nothing
            mortgage = seller.mortgages_held[m_idx]
            debt_to_settle = mortgage.remaining_principal
            seller_debt_for_tx = debt_to_settle

        # Repay the bank: its outstanding credit falls by the full remaining principal in both
        # settlement modes below.
        model.bank.outstanding_credit -= debt_to_settle
        #
        # Settlement of the seller's loan. `Config.D3_ZOMBIE_DEBT` selects what happens when the
        # seller's funds do not cover the loan:
        #
        # false (default, paper behaviour): full discharge. The bank's cash reserves rise by the
        #   whole remaining principal and the mortgage record is removed, whatever the seller's
        #   balance. The paper states that there is no limit in principle on credit supply or on
        #   fiat money creation (Carro et al. 2022, Section 3.4), so the bank's cash reserves act
        #   as a statistical counter and not as a lending constraint. If the seller's balance
        #   becomes negative, `resolve_insolvency!` injects cash (Appendix A.4, Footnote 8:
        #   scheduled payments are always made by artificially injecting as much cash as
        #   necessary).
        #
        # true (Java behaviour, MortgageAgreement.payoff): the seller pays
        #   min(seller balance + price, remaining principal). Any residual stays as a loan in
        #   `seller.zombie_debts`, with its monthly payment scaled down in proportion, and is
        #   serviced monthly in process_income_and_obligations!. The bank's cash reserves receive
        #   only the amount actually paid.
        if Config.D3_ZOMBIE_DEBT
            # D3=true: partial payoff capped at available post-sale balance
            post_sale_balance = seller.bank_balance + price
            amount_paid       = min(post_sale_balance, debt_to_settle)
            residual          = debt_to_settle - amount_paid

            # Bank receives only the cash the seller can actually transfer
            model.bank.cash_reserves += amount_paid

            if residual > 0.0
                # --- ZOMBIE DEBT PATH ---
                # Scale monthly_payment proportionally to residual (MortgageAgreement.java:67-68):
                #   monthlyPayment *= (principal - amount) / principal
                base = debt_to_settle > 0.0 ? debt_to_settle : 1.0
                mortgage.monthly_payment     *= residual / base
                mortgage.remaining_principal  = residual
                # Move to zombie_debts: serviced each month in process_income_and_obligations!
                # (FinancialFlows.jl). Do NOT deleteat! — ownership transfers to zombie_debts.
                push!(seller.zombie_debts, mortgage)
                deleteat!(seller.mortgages_held, m_idx)
            else
                # Fully paid in one go — purge immediately
                deleteat!(seller.mortgages_held, m_idx)
            end
        else
            # Julia baseline: full phantom-cash discharge
            model.bank.cash_reserves += debt_to_settle

            # 2. Remove Mortgage object — immediate purge
            # Full unconditional discharge: default on final BTL
            # principal repayment is resolved by bankruptcy cash injection, not by
            # carrying forward a lingering obligation ("zombie debt").
            deleteat!(seller.mortgages_held, m_idx)
        end
    end

    # The seller receives the sale price net of the loan repaid.
    #
    # The balance change is normally non-negative: `put_on_market!` floors the listing price at
    # the remaining principal, and `update_for_sale_supply!` withdraws a listing whenever a price
    # cut would take it to or below the remaining principal, so a cleared sale has
    # price >= debt_to_settle. This matches the Java model (Household.manageHouse), which removes
    # an offer whose revised price is not above the principal. The relation also holds under
    # `Config.D3_ZOMBIE_DEBT`: only the cash received by the bank differs, not the seller's
    # balance change.
    seller.bank_balance += (price - debt_to_settle)
    
    # The seller remains the owner-occupier until the sale is finalised; a resident seller is
    # moved to social housing in the portfolio update at the end of this function.
    end # if house.owner_id !== nothing
    
    # 2. Handle Buyer (Financing)
    # Financing and contract terms are validated above before any settlement mutation.

    # B. Payment & Accounting
    buyer.bank_balance -= down_payment

    # With `model.spain_consumption_recording` set, the down payment is added to the one-shot
    # housing consumption counter (Java: Household.completeHousePurchase calls
    # addDownpaymentHousingConsumption right after the buyer's balance is debited).
    if model.spain_consumption_recording
        model.market_stats.downpayment_housing_consumption_counter += down_payment
    end

    # The bank has no liquidity constraint: a loan is issued whatever its cash reserves (as in the
    # Java model).
    
    if final_loan_principal > 0
        # Create Mortgage Record
        # origination_rate: freeze the bank rate at signing — Java: approval.monthlyInterestRate = getMortgageInterestRate()/12
        # (stored annually here; divided by 12 at each amortization step, matching Java's monthly application).
        # Increment global mortgage ID counter and assign contract ID.
        model.bank.mortgage_id_counter += 1
        new_mortgage = Mortgage(
            model.bank.mortgage_id_counter,
            house_id,
            final_loan_principal,
            final_loan_principal,
            tx_monthly_payment,
            model.bank.current_mortgage_rate, # origination_rate — frozen, never updated

            # `model.bank.current_spread` here as `spread_over_base` instead of the all-in
            # rate. The base rate component would then be re-applied each step from
            # `model.central_bank.base_rate`, making payments respond to policy changes.
            # Fixed-rate products should continue to snapshot the all-in rate here.
            tx_term_months,
            abmtime(model),
            false, # Default is_high_lti (calculated in register_mortgage!)
            # [Alignment Note] Java: MortgageAgreement.isBuyToLet — set at construction.
            # is_buy_to_let = !is_home. BTL investment iff agent is BTL investor AND already owns home.
            is_btl_purchase,                                                  # is_buy_to_let
            (origination_type == FTB)                                          # is_first_time_buyer (origination-stable)
        )
        
        push!(buyer.mortgages_held, new_mortgage)

        # --- REGULATORY: Register Mortgage ---
        # Sets new_mortgage.is_high_lti; updates per-type Bank monthly counters.
        # Java: Bank.requestLoan() uses the bid's BTLBid flag to determine isHome parameter.
        # Derive from buyer state: BTL investment = (has BTL gene AND already owns home)
        # is_home = !BTLBid ≡ !(is_btl_investor && tenure_status == OwnerOccupier)
        is_home = !is_btl_purchase
        register_mortgage!(model.bank, new_mortgage, buyer.annual_income,
                           origination_type, is_home, model;
                           down_payment=down_payment)

        # --- BANK ACCOUNTING: Issue Loan ---
        model.bank.outstanding_credit += final_loan_principal
        model.bank.cash_reserves -= final_loan_principal

        # Record the new mortgage in the monthly flow counters
        model.market_stats.mortgage_flow_temp += 1
        # Realised principal at clearance, as in the Java model's CreditSupply.newLendingAmount.
        # It is published as `new_lending_flow` and exposed by `get_new_lending_flow`.
        model.market_stats.mortgage_flow_principal_temp += final_loan_principal

        # Contract ID for the transaction log
        tx_mortgage_id = new_mortgage.mortgage_id
    else
        # Cash purchase: no mortgage record is created. Ownership is tracked through
        # `house.owner_id`; `mortgages_held` tracks debt only.
    end
    # A buyer who is homeless, renting or in social housing buys for habitation and becomes an
    # owner-occupier. A purchase by an agent who already owns a home is a buy-to-let purchase. A
    # buy-to-let investor who is currently renting is therefore treated like a first-time buyer.

    # Tenant eviction on the sale of a tenanted house.
    #
    # As in the Java model (Household.completeHouseSale, which removes the rental contract and calls
    # the resident's getEvicted()), selling a house with a resident evicts that resident, whatever
    # the type of buyer. Otherwise a tenant could keep an active lease on a house that now belongs to
    # someone else. Controlled by `Config.D26_EVICT_ON_NONBTL_SALE` (default true).
    #
    # Guard: the resident must exist and must be neither the buyer nor the seller. The buyer clause
    # covers a renter who buys the house they currently rent: that buyer becomes an owner-occupier
    # in the renter-to-owner block below and must not be evicted. The Java model does not need the
    # clause because its bid pool excludes a resident's own rental, whereas here the bid pool admits
    # it.
    #
    # Bookkeeping: the block evicts the tenant (clears the rental agreement and residence and sets
    # tenure to social housing, as Java's getEvicted() does), decrements
    # `occupied_rentals_by_quality` and clears `house.resident_id`. It leaves
    # `vacant_rentals_by_quality` unchanged, because what happens next depends on the buyer:
    #   - A buyer who moves in (renter, social housing, first-time buyer): the house leaves the
    #     rental pool, so occupied falls by one and vacant is unchanged.
    #   - A buy-to-let buyer: the house is relisted for rent below, where `active_rental_listings`
    #     and `vacant_rentals_by_quality` are incremented, so occupied falls by one and vacant
    #     rises by one.
    # Both flows keep the rental stock balanced, so the vacant count is not incremented here.
    if Config.D26_EVICT_ON_NONBTL_SALE &&
       house_had_tenant &&
       house.resident_id !== nothing && Agents.hasid(model, house.resident_id) &&
       house.resident_id != buyer_id &&
       house.resident_id != previous_owner_id
        tenant = model[house.resident_id]
        # Evict only a true tenant state; never evict the owner/seller path.
        if tenant.tenure_status == Renter || tenant.rental_agreement !== nothing
            tenant.rental_agreement = nothing
            tenant.residence_id = nothing
            tenant.tenure_status = SocialHousing
            # Update stats: property transitions occupied → (handled downstream)
            if 1 <= house.quality <= length(model.market_stats.occupied_rentals_by_quality)
                model.market_stats.occupied_rentals_by_quality[house.quality] =
                    max(0, model.market_stats.occupied_rentals_by_quality[house.quality] - 1)
            end
            house.resident_id = nothing
        end
    end

    if buyer.tenure_status == SocialHousing || buyer.tenure_status == Renter || buyer.residence_id === nothing
        
        # Scenario: Renter -> Owner
        if buyer.tenure_status == Renter && buyer.residence_id !== nothing
             # Vacate previous rental
             old_rental_id = buyer.residence_id
             old_house = model.housing_stock[old_rental_id]
             
             # Vacate
             old_house.resident_id = nothing
             
             # Update Rental Stats (Occupied -> Vacant)
             model.market_stats.occupied_rentals_by_quality[old_house.quality] -= 1
             model.market_stats.vacant_rentals_by_quality[old_house.quality] += 1
             
             # Reset Lease
             buyer.rental_agreement = nothing
             old_house.is_for_rent = true # Put back on market
             
             # Return to active pool
             push!(model.market_stats.active_rental_listings, old_house.id)
        end

        buyer.residence_id = house_id
        
        # State Transition
        buyer.tenure_status = OwnerOccupier
        # Note: borrower_type stays as FTB or HM until they sell again, 
        # but for future mortgage logic, simple ownership check usually suffices.
        
        # Update House Resident
        house.resident_id = buyer_id

        # A buyer without a residence moves in and is no longer a first-time buyer.
    else
        # Investment property (buy-to-let). On the sales market such a house is normally vacant,
        # because yield-based selling only applies to vacant houses, but an occupied house can still
        # be sold. Any tenant was evicted in the eviction block above, so no eviction is needed in
        # this branch.
        house.resident_id = nothing

        # Set Initial Ask Rent (Carro Eq 9)
        # r_s = r_Q * markup_ratio (level-space; markup_ratio = exp(η_paper))
        # We use the Market EMA rent as a proxy for r_Q (Quality Rent).
        # Use Quality-Specific EMA for segmented pricing
        base_rent = model.market_stats.ema_rents_by_quality[house.quality]
        if base_rent <= 0.0; base_rent = Config.INITIAL_AVG_RENT; end
        
        # Level-space markup ratio from Zoopla empirical distribution (Table 12)
        markup_ratio = draw_rental_markup(model) 
        
        # Empirical data provides the ratio directly.
        house.rental_price = base_rent * markup_ratio
        
        # The house is now owned, vacant and not for sale. It is flagged for rent and enters the
        # rental market supply in the next step.
        house.is_for_rent = true
        # Reset the rental age. A house entering the rental market from a sale is a new listing,
        # so `update_rental_supply!` must treat it as fresh (month 0) and not cut its price in the
        # same step (Java: Household.java checks against the initial listing time).
        house.months_on_rental_market = 0 
        
        push!(model.market_stats.active_rental_listings, house_id)
        model.market_stats.vacant_rentals_by_quality[house.quality] += 1
    end
    
    # 3. Update House State
    house.owner_id = buyer_id
    house.is_for_sale = false
    tx_months_on_market = house.months_on_market  # Captured before the reset below, for the time-on-market statistics
    house.months_on_market = 0

    # --- Transaction log ---
    # Every transaction is logged; filtering by period is done in data collection and analysis.
    if abmtime(model) >= 0 
        wealth_before = buyer.bank_balance + down_payment 
        tx_income_percentile = clamp(buyer.income_percentile, 0.0, 1.0)
        tx_permanent_income_quintile = clamp(ceil(Int, tx_income_percentile * 5.0), 1, 5)

        # Calculate Ratios
        ltv = final_loan_principal / price
        lti = (buyer.annual_income > 0) ? (final_loan_principal / buyer.annual_income) : 0.0
        
        # Use captured origination classification for transaction labeling.
        b_type = origination_type
        
        # C.4: Classify seller at moment of sale (before portfolio update)
        if previous_owner_id !== nothing && previous_owner_id in allids(model)
            _seller = model[previous_owner_id]
            s_type = if _seller.is_btl_investor
                "BTL"
            elseif seller_was_resident
                "OO"
            else
                "OTHER"   # non-BTL selling non-residence (inherited surplus)
            end
            s_borrower_type = _seller.borrower_type
        else
            s_type = "NONE"
            s_borrower_type = buyer.borrower_type
        end

        tx_record = Transaction(
            abmtime(model),
            house_id,
            buyer_id,
            previous_owner_id,
            tx_mortgage_id,
            price,
            final_loan_principal,
            down_payment,
            buyer.annual_income,
            tx_income_percentile,
            tx_permanent_income_quintile,
            wealth_before,
            ltv,
            lti,
            b_type,
            Int(floor(buyer.age)),
            is_btl_purchase,
            house.quality,
            seller_debt_for_tx,  # seller's remaining principal on this property
            tx_monthly_payment,  # C.1: monthly debt service (0.0 for cash)
            tx_months_on_market, # C.5: time-to-sale in months
            final_loan_principal > 0 ? model.bank.current_mortgage_rate : 0.0,  # C.2: origination rate
            tx_term_months,      # C.3: age-adjusted term at origination (0 for cash)
            s_type,              # C.4: seller classification (BTL/OO/OTHER/NONE)
            s_borrower_type,     # exact seller borrower type at sale time
            buyer.desired_purchase_price,
            bid_p_max
        )
        
        # Access log from model properties
        push!(model.transaction_log, tx_record)
    end

    # Update Asset Lists
    # Add to Buyer
    push!(buyer.properties_owned, house_id)

    # A purchase ends first-time-buyer status: the buyer becomes a home mover (as in the Java
    # model, where Household.completeHouseSale clears `isFirstTimeBuyer` on every purchase).
    # Otherwise an owner-occupier could still be labelled a first-time buyer.
    # Controlled by `Config.D25B_CLEAR_FTB_ON_PURCHASE` (default true). Consumes no random numbers.
    if Config.D25B_CLEAR_FTB_ON_PURCHASE && buyer.borrower_type == FTB
        buyer.borrower_type = HM
    end

    # Remove from Seller (if not bank/init)
    if previous_owner_id !== nothing && previous_owner_id in allids(model)
        seller = model[previous_owner_id]
        # Find and delete the house_id from seller's portfolio
        filter!(x -> x != house_id, seller.properties_owned)
        
        # Displacement of a resident seller
        # If the seller was living in the sold house, they move to Social Housing
        if seller_was_resident
            seller.residence_id = nothing
            seller.tenure_status = SocialHousing
            seller.borrower_type = HM # Transitions to Home Mover
        end
    end
    
    # 4. Remove from Active Sales Listings (Sold!)
    # This keeps the optimization set consistent.
    delete!(model.market_stats.active_sales_listings, house_id)

    # RECORD FOR ORACLE:
    # Push to Quality-Specific Bin for Segmented EMA
    push!(model.market_stats.current_sales_by_quality[house.quality], price)
    push!(model.market_stats.current_mom_by_quality[house.quality], tx_months_on_market)
    
    # Aggregate statistics are derived from these quality-specific bins when the market
    # statistics are updated, so no separate global list is kept.
    @assert !(house.resident_id == previous_owner_id && house.owner_id == buyer_id) "Resident-owner stale after sale"
    return true
end

  


"""
    update_for_sale_supply!(model)
Implements the Seller Brain (Supply Side) - Full Replication (Carro et al. 2022).

Mechanisms implemented:
1. Price Revision: Stochastic exponential decay (Page 15).
2. Withdrawal: Negative Equity protection (Page 15).
3. New Listings:
    - Exogenous Moving (1/17 years).
    - Empty/Inherited Properties.
    - Financial Distress (Bankruptcies).
"""
function update_for_sale_supply!(model)
    # --- Parameters ---
    # Supply Side (Table 11)
    prob_cut = model.params.sale_price_reduction_prob
    mu_cut = model.params.sale_price_reduction_mean
    sigma_cut = model.params.sale_price_reduction_std
    
    # Exogenous Moving Probability (Table 11: "Holding period... 17 years")
    # Probability = 1 / (17 * 12)
    # The monthly probability is pre-calculated in ModelParameters to avoid redundancy
    moving_prob = model.params.p_sale_monthly

    # Distribution for epsilon (Normal noise for price cut)
    # Note: Text says "epsilon is a normal noise". Table 11 gives Mean/Std.
    dist_epsilon = Normal(mu_cut, sigma_cut)

    # =========================================================================
    # 1. Price Revision (Existing Listings)
    # Reference: Page 15, "For each month... new price will be p(t) = p(t-1)(1 - exp(eps))"
    # =========================================================================
    # SAFETY: We collect keys because we might delete from the set during iteration (Withdrawal).
    for house_id in collect(model.market_stats.active_sales_listings)
        house = model.housing_stock[house_id]
        if house.is_for_sale
            house.months_on_market += 1
            
            # A. Calculate PROPOSED new price (Java: newPrice = rethinkHouseSalePrice())
            # This matches Java's pattern: calculate first, check second, mutate third
            proposed_price = house.listing_price  # Default: keep current price
            
            # Stochastic Trigger (Monthly probability ~0.0703)
            # Java Parity: Skip price reduction if listed this month
            # Java: if (Model.getTime() > forSale.gettInitialListing())
            # At listing time t: tInitialListing = t, so t > t is FALSE (no reduction)
            # At time t+1: t+1 > t is TRUE (reduction can occur)
            # Equivalent: months_on_market = 0 at listing, increments to 1, so check > 1
            if house.months_on_market > 1 && rand(abmrng(model)) < prob_cut
                # Calculate Reduction Factor
                # Formula: p_new = p_old * (1 - exp(eps)/100)
                # Matches Java rethinkHouseSalePrice Logic 100%
                # 1. log_reduction ~ Normal(1.453..., 0.707...)
                log_reduction = rand(abmrng(model), dist_epsilon)
                
                # 2. Convert to percentage drop
                # e.g., if log_reduction = 1.45 (Mean), drop = e^1.45 / 100 ≈ 4.27%
                percentage_drop = exp(log_reduction) / 100.0

                # 3. Cap max reduction at 50% (Java: Math.max(1.0 - drop, 0.5))
                # Effectively limits percentage_drop to <= 0.5
                percentage_drop = min(percentage_drop, 0.5)

                # 4. Calculate proposed price (DON'T mutate yet)
                proposed_price = house.listing_price * (1.0 - percentage_drop)
            end
                
            # B. Mortgage Withdrawal Rule (Negative Equity Protection)
            # Reference: Page 15 "If price drops below outstanding mortgage... offer is withdrawn"
            # Java Logic: if (newPrice > principal) updateOffer(newPrice) else removeOffer()
            # Check PROPOSED price BEFORE mutation
            should_withdraw = false
            if house.owner_id !== nothing
                # Safety: owner may have been removed (death/demographics)
                owner = nothing
                try
                    owner = model[house.owner_id]
                catch
                    continue  # Skip this house, owner no longer exists
                end
                
                # Find specific mortgage
                mortgage = nothing

                for m in owner.mortgages_held
                    if m.house_id == house.id
                        mortgage = m
                        break
                    end
                end
                
                # Check Negative Equity on PROPOSED price (not current price)
                # Java: if (newPrice > principal) -> Update, else -> Remove
                # Therefore: if (proposed_price <= principal) -> Withdraw
                if mortgage !== nothing
                    if proposed_price <= mortgage.remaining_principal
                        should_withdraw = true
                    end
                end
            end

            # Java's `Household.java:258` wraps BOTH the price-cut RNG AND the
            # negative-equity withdrawal in a single grace gate
            # `if (Model.getTime() > forSale.gettInitialListing())`. Julia's cut
            # RNG is already gated by `mom > 1` above; this block extends the
            # same gate to the withdrawal so that on the listing tick (mom == 1
            # in Julia counting) the house is left untouched, matching Java.
            if house.months_on_market <= 1
                should_withdraw = false
            end

            # C. Apply Decision (Withdraw OR Update)
            if should_withdraw
                # Withdraw from market WITHOUT updating price
                # This preserves the pre-withdrawal price in house state
                house.is_for_sale = false
                house.months_on_market = 0
                delete!(model.market_stats.active_sales_listings, house_id)
                model.market_stats.n_withdrawals += 1
            else
                # Safe to update price (matches Java's updateOffer)
                house.listing_price = proposed_price
            end
        end
    end

    # =========================================================================
    # 2. New Listings (The Flow)
    # =========================================================================
    
    # Keeping the Ghost Asset check below as it is a market cleaning step 
    # ensuring non-BTL empty homes are rented out.


    # C. Empty/Surplus Property Check (Heirs & Passive Investors)
    # Reference: Appendix A.1, A.2
    # "Owner-occupier households receiving more than one house will put the
    #  resulting extra properties for sale." (A.1)
    # "Owner-occupiers will put the inherited house for sale while also
    #  temporarily offering it for rent." (A.2)
    #
    # Scans housing stock for owned-but-vacant properties that are not listed
    # for sale. This catches inherited properties that were never listed or
    # were withdrawn due to negative equity (price < principal). Non-BTL
    # owner-occupiers always relist surplus properties — the paper has no
    # portfolio-size guard; the only exit from relisting is a successful sale
    # or the negative-equity withdrawal in the price-revision step.
    #
    # BTL investors are excluded because they have dedicated yield-based
    # sell/keep logic in Phase 3 above.
    
    for house in model.housing_stock
        if house.owner_id !== nothing
            # Safety: owner may have been removed (death/demographics)
            owner = nothing
            try
                owner = model[house.owner_id]
            catch
                continue  # Skip this house, owner no longer exists
            end
             
             # If it's empty and not for sale...
             if house.resident_id === nothing && !house.is_for_sale
                 
                 # Exclude BTL Investors (They have their own Logic in Phase 3 above)
                 # BTL investors can choose to "Keep" the property (Rent Only).
                 if owner.is_btl_investor
                     continue
                 end

                 # Non-BTL owner-occupiers: relist surplus property for sale + rent
                 # Per paper Appendix A.1/A.2: always attempt to sell, offer for rent
                 if owner.residence_id != house.id
                      if Config.ND36_MODE === :JAVA
                          nprops = length(owner.properties_owned)
                          if nprops < 3
                              continue
                          elseif !evaluate_investor_exit(owner, house, model)
                              continue
                          end
                      elseif Config.ND36_MODE === :PAPER
                          if rand(abmrng(model)) >= model.params.p_sale_monthly
                              continue
                          end
                      end

                      if !house.is_for_rent
                          house.is_for_rent = true
                          push!(model.market_stats.active_rental_listings, house.id)
                          model.market_stats.vacant_rentals_by_quality[house.quality] += 1
                      end
                      put_on_market!(house, model)
                 end
             end
        end
    end
end

"""
    put_on_market!(house, model)
Helper to list a house for sale.
Sets initial listing price using Equation 6.

Reference: Carro et al. (2022) Eq 6, Page 15
Paper notation: ln(p_s) = ln(p_Q) + η, where η is a log-space additive markup.
Implementation: p_s = p_Q × markup_ratio, where markup_ratio is drawn directly
from the level-space empirical distribution (Zoopla, Table 11). The data file
`InitialSaleMarkUpDist.csv` contains ratio bins [0.5, 2.0], not log bins.
The code variable `markup_ratio` equals exp(η_paper); no exponentiation is needed.
"""
function put_on_market!(house, model)
    stats = model.market_stats
    
    # 1. Baseline Price (p_avg)
    # Use the segmented average (quality-specific EMA) per Eq 6.
    # We consciously REJECT "Valuation Anchoring" (Loss Aversion) as Carro et al. (2022) 
    # simplified this to focus only on market prices.
    

    # The paper states that "exponential moving averages... are initialised as estimated from data".
    # Analysis: The ema_prices vector should be pre-filled during the model.spin_up phase using the distribution data from Table 10. 
    # Therefore, p_Q should never be 0, even at step 1.
    # Logic: Use the EMA. If 0 (t=0 safety), fallback to reference price for that quality.
    p_quality = stats.ema_prices_by_quality[house.quality]
    baseline_price = p_quality > 0.0 ? p_quality : stats.reference_prices_by_quality[house.quality]
    
    # 2. Markup (level-space ratio)
    # Reference: Table 11 "Estimated distribution... Source: Zoopla"
    # Returns a multiplicative ratio ∈ [0.5, 2.0] sampled from the empirical distribution.
    markup_ratio = draw_sales_markup(model)
    
    # 3. Principal Floor (Java Parity)
    # Java: getInitialSalePrice ensures price >= principal.
    # We must ensure we don't list below principal, because the withdrawal logic
    # would immediately pull it (lock-in effect).
    principal = 0.0
    if house.owner_id !== nothing
        owner = model[house.owner_id]
        # Search for mortgage on this house
        for m in owner.mortgages_held
            if m.house_id == house.id
                principal = m.remaining_principal
                break
            end
        end
    end

    # 4. List It
    house.is_for_sale = true
    house.months_on_market = 0
    # Eq 6: p_s = p_Q * markup_ratio (level-space ratio from Zoopla empirical dist)
    # Floor at principal to prevent immediate negative equity withdrawal
    house.listing_price = max(baseline_price * markup_ratio, principal)
    
    # 5. Add to Active Listings (Start Tracking)
    push!(stats.active_sales_listings, house.id)
end

"""
    draw_sales_markup(model)
Returns a level-space markup ratio for the SALES market (Eq 6).
The returned value is exp(η_paper) — a multiplicative ratio ∈ [0.5, 2.0].


"""
function draw_sales_markup(model)
   return sample_markup(abmrng(model), model.sale_markup_dist)
end


