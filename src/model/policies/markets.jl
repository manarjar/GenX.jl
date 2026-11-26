@doc raw"""
    markets!(EP::AbstractModel, inputs::Dict, setup::Dict)

This module represents electricity transactions between a zone and an external wholesale market.
Market zones ``z \in \mathcal{M}`` can buy electricity from the market (imports) and sell
electricity to the market (exports) at exogenous hourly prices. Market transactions can be used
to represent, for example, unspecified imports from resources outside the modeled balancing area.

**Decision variables**

- ``\Pi^{Mkt}_{z,t} \geq 0``: electricity bought from the market (imports) in zone ``z`` at time ``t`` (`vMBUY`)
- ``\Theta^{Mkt}_{z,t} \geq 0``: electricity sold to the market (exports) in zone ``z`` at time ``t`` (`vMSELL`)
- ``\nu^{Mkt}_{z,t} \in \{0,1\}``: market direction variable (`vMACTIVE`), created only when
  `MarketDualFlow = 0`

**Transaction limits**

Imports and exports are bounded by zonal transaction limits ``\overline{\Pi}^{Mkt}_{z}`` and
``\overline{\Theta}^{Mkt}_{z}`` (from `Zones_markets.csv`). When `MarketDualFlow = 1`, imports and
exports may occur simultaneously:

```math
\begin{aligned}
    & 0 \leq \Pi^{Mkt}_{z,t} \leq \overline{\Pi}^{Mkt}_{z} & \quad \forall z \in \mathcal{M}, t \in \mathcal{T} \\
    & 0 \leq \Theta^{Mkt}_{z,t} \leq \overline{\Theta}^{Mkt}_{z} & \quad \forall z \in \mathcal{M}, t \in \mathcal{T}
\end{aligned}
```

When `MarketDualFlow = 0`, a binary variable ``\nu^{Mkt}_{z,t} \in \{0,1\}`` enforces that a zone
either imports or exports in each time step, but not both:

```math
\begin{aligned}
    & \Pi^{Mkt}_{z,t} \leq \overline{\Pi}^{Mkt}_{z} \, \nu^{Mkt}_{z,t} & \quad \forall z \in \mathcal{M}, t \in \mathcal{T} \\
    & \Theta^{Mkt}_{z,t} \leq \overline{\Theta}^{Mkt}_{z} \, (1 - \nu^{Mkt}_{z,t}) & \quad \forall z \in \mathcal{M}, t \in \mathcal{T}
\end{aligned}
```

Note that this option makes the model a mixed-integer program.

**Export limit based on local supply and net imports**

To limit arbitrage against the market, exports cannot exceed the electricity supplied by
resources located in the zone, ``G_z`` (`eMaxMarketExportByZone`), plus net imports from other
modeled zones over the transmission network, minus the zone's share of transmission losses:

```math
\begin{aligned}
    & \Theta^{Mkt}_{z,t} \leq \sum_{y \in G_z} \Theta_{y,t}
      - \sum_{l \in \mathcal{L}} \varphi^{map}_{l,z} \, \Phi_{l,t}
      - \frac{1}{2} \sum_{l \in \mathcal{L}} \lvert \varphi^{map}_{l,z} \rvert \, \beta_{l,t}(\cdot)
      & \quad \forall z \in \mathcal{M}, t \in \mathcal{T}
\end{aligned}
```

Here ``\Theta_{y,t}`` is the output of resource ``y``. Storage, VRE-STOR, Allam cycle, and fusion
resources contribute their grid injection only, not net of the electricity they draw from the
grid (storage charging, grid supply to the Allam cycle air separation unit, or fusion parasitic
load). ``\Phi_{l,t}`` is the power flow on line ``l``, ``\varphi^{map}_{l,z}`` is the
line-to-zone network map (positive when flow on ``l`` leaves zone ``z``), and ``\beta_{l,t}(\cdot)``
are the losses on line ``l`` (see [`transmission!`](@ref)). The second term
(`eNet_Export_Flows`) is the net interzonal export from zone ``z``, so imports from other zones
increase the amount that can be sold to the market and exports to other zones reduce it. The third
term (`eLosses_By_Zone`) assigns half of each connected line's losses to the zone. In single-zone
cases, where there is no transmission network, these two terms are omitted.

Combined with the power balance, this constraint is equivalent to limiting market purchases to
the zone's own consumption:

```math
\begin{aligned}
    & \Pi^{Mkt}_{z,t} \leq D_{z,t} - \sum_{s} \Lambda_{s,z,t} + \sum_{y \in \mathcal{O}_z} \Pi_{y,t}
      & \quad \forall z \in \mathcal{M}, t \in \mathcal{T}
\end{aligned}
```

where ``D_{z,t}`` is demand, ``\Lambda_{s,z,t}`` is non-served energy, and ``\Pi_{y,t}`` is the
electricity drawn from the grid by storage, VRE-STOR, Allam cycle, and fusion resources
``\mathcal{O}_z`` in the zone. (Other loads that enter
the power balance but not ``G_z``, such as flexible demand, also add to this limit.) Market
purchases can therefore serve local demand and charge storage, but cannot be passed on to other
zones over the transmission network. Storage can buy from the market in one hour and sell the
stored energy to the market in a later hour.

Because net imports from other zones count toward the sales limit while market purchases are
limited to local consumption, the role a market zone can play depends on what it contains:

- A zone with no demand and no storage cannot buy from the market. It can sell its own
  generation and electricity imported from other zones.
- A zone with no generation and no storage can buy up to its own demand, but cannot be a net
  exporter over the transmission network. It can sell only electricity imported from other zones.
- A zone with both generation and demand can buy to serve its own demand and export its local
  generation over the transmission network or to the market.

**Arbitrage within a zone**

The constraint above limits the *volume* of purchases, not the use of the electricity. Whether a
zone can buy and resell in the same time step depends on `MarketDualFlow`:

- With `MarketDualFlow = 0`, a zone cannot buy and sell in the same time step, so electricity
  bought from the market in a given hour cannot be resold to the market in that hour.
- With `MarketDualFlow = 1`, a zone may buy and sell in the same time step. Electricity bought
  from the market can serve local demand or charge storage and free up local generation for
  sale, so the zone can effectively resell market purchases, up to its demand plus storage
  charging. This is only profitable when ``\pi^{sell}_{z,t} > \pi^{buy}_{z,t}``. Market prices are
  therefore expected to satisfy ``\pi^{sell}_{z,t} \leq \pi^{buy}_{z,t}`` in every zone and time
  step, in which case buying and selling in the same time step is never profitable and resale
  does not occur without the need for binary variables. This condition is not checked when the
  inputs are read.

Buying in one time step, storing the electricity and selling it in a later time step is allowed
in both cases, with the storage round-trip losses.

!!! warning "Cross-zone market arbitrage"
    In multi-zone cases with more than one market zone, market purchases cannot be passed directly
    through the transmission network, but they can reach other zones indirectly: a zone buys from
    the market to serve its own demand or charge storage, and exports the local generation it no
    longer needs to another market zone, which sells it. The volume is limited by the buying
    zone's demand plus storage charging. This happens whenever the sell price in the receiving
    zone exceeds the buy price in the sending zone by more than the transmission losses,
    regardless of the `MarketDualFlow` setting. No check is applied to the input prices, so
    review market prices across zones if such flows are not intended.

**Power balance**

Imports are added to the zonal power balance as a source of electricity, and exports as an
additional use:

```math
\begin{aligned}
    & \text{ePowerBalance}_{z,t} \mathrel{+}= \Pi^{Mkt}_{z,t} - \Theta^{Mkt}_{z,t} & \quad \forall z \in \mathcal{M}, t \in \mathcal{T}
\end{aligned}
```

**CO``_2`` emissions**

Emissions from imported electricity are assigned to the importing zone, using an hourly emission
rate ``\epsilon^{Mkt,CO_2}_{z,t}`` in tCO``_2``/MWh (from `Market_emissions.csv`):

```math
\begin{aligned}
    & E^{Mkt,CO_2}_{z,t} = \epsilon^{Mkt,CO_2}_{z,t} \, \Pi^{Mkt}_{z,t} & \quad \forall z \in \mathcal{M}, t \in \mathcal{T}
\end{aligned}
```

These emissions are added to `eTotalEmissionsByZone` and count toward any CO``_2`` cap, so imported
electricity is subject to the same emissions accounting as in-zone generation. Exports are not
credited, because their emissions are already counted at the generating resources.

**Objective function**

The cost of imports and the revenue from exports, at hourly buy prices ``\pi^{buy}_{z,t}`` and sell
prices ``\pi^{sell}_{z,t}`` (from `Market_price.csv`), are added to the objective function,
weighted by the time-step weights ``\omega_t``:

```math
\begin{aligned}
    & \sum_{z \in \mathcal{M}} \sum_{t \in \mathcal{T}} \omega_t \left( \pi^{buy}_{z,t} \, \Pi^{Mkt}_{z,t} - \pi^{sell}_{z,t} \, \Theta^{Mkt}_{z,t} \right)
\end{aligned}
```
"""

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

    # Market exports cannot exceed local generation plus net interzonal imports, less losses
    if Z > 1
        @constraint(EP, [m in MZ, t in 1:T],
            EP[:eMaxMarketExportByZone][m, t]
            - EP[:eNet_Export_Flows][m, t]
            - EP[:eLosses_By_Zone][m, t] >= vMSELL[m, t])
    else
        @constraint(EP, [m in MZ, t in 1:T],
            EP[:eMaxMarketExportByZone][m, t] >= vMSELL[m, t])
    end

    ### Power Balance Update ###
    # Only market zones have vMBUY/vMSELL entries, so update their balances directly
    for m in MZ, t in 1:T
        add_to_expression!(EP[:ePowerBalance][t, m], vMBUY[m, t])
        add_to_expression!(EP[:ePowerBalance][t, m], -1.0, vMSELL[m, t])
    end

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
