# src/institutions/Government.jl

# 1. Specialized helper for NI (Applies to WAGE only)
function calculate_ni(wage_income::Float64)
    wage_income <= Config.NI_PRIMARY_THRESHOLD && return 0.0
    
    ni_tax = 0.0
    
    # Main Rate (12%)
    niable_main = min(wage_income, Config.NI_UPPER_EARNINGS_LIMIT) - Config.NI_PRIMARY_THRESHOLD
    ni_tax += niable_main * Config.NI_RATE_MAIN
    
    # Additional Rate (2%)
    if wage_income > Config.NI_UPPER_EARNINGS_LIMIT
        niable_add = wage_income - Config.NI_UPPER_EARNINGS_LIMIT
        ni_tax += niable_add * Config.NI_RATE_ADDITIONAL
    end
    
    return ni_tax
end

# 2. Specialized helper for Income Tax (Applies to Taxable Income)
function calculate_income_tax(taxable_income::Float64)
    taxable_income <= 0 && return 0.0
    
    tax = 0.0
    
    # Basic Rate (20%)
    basic_portion = min(taxable_income, Config.TAX_BAND_BASIC_LIMIT)
    tax += basic_portion * Config.TAX_RATE_BASIC
    
    remaining = taxable_income - basic_portion
    if remaining > 0
        # Higher Rate (40%)
        # Note: In 2011, the Higher band width is strictly defined by the gap 
        # between the Basic Limit and the Additional Threshold (150k).
        higher_band_width = 150000.0 - Config.TAX_BAND_BASIC_LIMIT
        
        higher_portion = min(remaining, higher_band_width)
        tax += higher_portion * Config.TAX_RATE_HIGHER
        
        # Additional Rate (50%)
        remaining -= higher_portion
        if remaining > 0
            tax += remaining * Config.TAX_RATE_ADDITIONAL
        end
    end
    
    return tax
end

# 3. The Master Function (Handles Agent Heterogeneity)
"""
    calculate_net_income(wage_income, rental_income, finance_costs)
Applies the 2011 UK Tax Wedge (Income Tax + National Insurance) with BTL considerations.
Returns a tuple: (net_income, total_tax)

Arguments:
- wage_income: Gross annual income from employment (subject to NI + IT)
- rental_income: Gross annual income from properties (subject to IT only)
- finance_costs: Annual mortgage interest costs (deductible for BTL IT)
"""
function calculate_net_income(wage_income::Float64, rental_income::Float64=0.0, finance_costs::Float64=0.0)
    
    # --- Step A: Determine Gross for Income Tax ---
    # Java Alignment: Relief applies to global income, not ring-fenced to rent.
    # Logic: Total Income - Finance Costs
    gross_total_income = wage_income + rental_income
    
    # Apply Finance Relief (Global Offset)
    # Household.java passes (GrossTotal - FinanceCosts) to incomeTaxDue
    adj_gross_income = max(0.0, gross_total_income - finance_costs)

    # --- Step B: National Insurance ---
    # Java Alignment: Applied to WAGE INCOME ONLY (Class 1 NICs)
    # Household.java line 206: class1NICsDue(annualGrossEmploymentIncome)
    # The paper confirms the Class 1 basis.
    ni_bill = calculate_ni(wage_income)

    # --- Step C: Personal Allowance Taper ---
    # Taper is based on Adjusted Net Income (adj_gross_income here)
    allowance = Config.TAX_PERSONAL_ALLOWANCE
    if adj_gross_income > Config.TAX_INCOME_LIMIT
        reduction = (adj_gross_income - Config.TAX_INCOME_LIMIT) / 2.0
        allowance = max(0.0, allowance - reduction)
    end

    # --- Step D: Final Calculation ---
    taxable_income = max(0.0, adj_gross_income - allowance)
    income_tax_bill = calculate_income_tax(taxable_income)

    total_tax = ni_bill + income_tax_bill
    
    # Net Income = (Wage + Rent) - Taxes
    # Java Alignment: Finance costs reduce taxable income (tax relief), but are NOT
    # subtracted from net income because they are paid separately as housing costs.
    # Java: getMonthlyNetTotalIncome() = monthlyGross - tax/12
    net_income = gross_total_income - total_tax

    return net_income, total_tax
end
