#we will have a market for every generator by having a mapping table between generator and markets
function markets!(EP::AbstractModel, inputs::Dict, setup::Dict)
    T   = inputs["T"]      # Number of time steps
    Z   = inputs["Z"]      # Total zones
    MZ  = inputs["MZ"]     # Market zones
    w   = inputs["omega"]  # Time weights (if any)

    ### Decision Variables ###
    @variable(EP, vMBUY[m in MZ, t=1:T] >= 0)   # Energy imported
    @variable(EP, vMSELL[m in MZ, t=1:T] >= 0)  # Energy exported

    # Market direction / exclusivity
    if setup["MarketDualFlow"] == 1
        # Relaxed: allow simultaneous buy & sell
        @variable(EP, 0 <= vMACTIVE[m in MZ, t=1:T] <= 1)
        @constraint(EP, [m in MZ, t in 1:T], vMBUY[m,t] <= inputs["Mrkt_Max_Buy"][m])
        @constraint(EP, [m in MZ, t in 1:T], vMSELL[m,t] <= inputs["Mrkt_Max_Sell"][m])
    else
        # Enforce mutual exclusivity with binary
        @variable(EP, vMACTIVE[m in MZ, t=1:T], Bin)
        @constraint(EP, [m in MZ, t in 1:T],
            vMBUY[m,t] <= inputs["Mrkt_Max_Buy"][m] * vMACTIVE[m,t])
        @constraint(EP, [m in MZ, t in 1:T],
            vMSELL[m,t] <= inputs["Mrkt_Max_Sell"][m] * (1 - vMACTIVE[m,t]))
    end

    # Market exports cannot exceed local generation
    @constraint(EP, [m in MZ, t in 1:T], EP[:eTotalGenerationByZone][m,t] >= vMSELL[m,t])

    ### Power Balance Update ###
    @expression(EP, eZonalNetMarkets[t=1:T, z=1:Z],
        z in MZ ? vMBUY[z,t] - vMSELL[z,t] : EP[:vZERO])
    add_similar_to_expression!(EP[:ePowerBalance], eZonalNetMarkets)

    ### Market CO₂ Emissions ###
    for m in MZ, t in 1:T
        add_term_to_expression!(EP[:eTotalEmissionsByZone][m,t],
            inputs["Market_CO2_tons_MWh"][m,t] * vMBUY[m,t])
    end

    ### Market Costs (Objective) ###
    MarketBuy  = inputs["Market_BuyPrices"]
    MarketSell = inputs["Market_SellPrices"]

     @expression(EP, eCMarketBuy[m in MZ],
        sum(MarketBuy[m,t]  * vMBUY[m,t]  * w[t] for t in 1:T))
        
    @expression(EP, eCMarketSell[m in MZ],
        -1*sum(MarketSell[m,t] * vMSELL[m,t] * w[t] for t in 1:T))

    @expression(EP, eTotalCMarketBuy, sum(eCMarketBuy[m] for m in MZ)) 
    @expression(EP, eTotalCMarketSell, sum(eCMarketSell[m] for m in MZ))

    add_to_expression!(EP[:eObj], eTotalCMarketBuy)
    add_to_expression!(EP[:eObj], eTotalCMarketSell)
end
