# Morpho Midnight on ForeignController

`ForeignController` integrates the Morpho Midnight singleton (`morpho-org/midnight @ 70607569`) for the ALMProxy as a lender only. It supports two modes:

- **Taker mode** (`RELAYER`): `buyMidnight`, `sellMidnight` and `redeemMidnight` take other makers' offers and redeem at maturity.
- **Maker mode**: the proxy publishes its own offers. A third party fills them by calling `midnight.take` directly, so none of our transactions is in the call stack. Two immutable periphery contracts (`grove-morpho-midnight-periphery`) act for the controller in that stack. A **ratifier** decides whether an offer is live. A **funding strategy**, named as the offer's `callback`, calls `midnight_fundFill` from inside `onBuy` / `onSell`.

The logic lives in `MidnightLib`, and the controller holds the configuration and the role checks. The same periphery also serves the diamond-pau `MidnightFacet`, through the same two selectors with the same semantics.

## Periphery-facing surface

| Function | Selector | Access |
|---|---|---|
| `midnight_fundFill(bytes32 marketId, bool buy, uint256 assets, uint256 units, uint256 pendingFee)` | `0xfb9e2099` | roleless, `nonReentrant` |
| `midnight_isCallbackAllowed(bytes32 marketId, address callback, bool buy) returns (bool)` | `0x5c0f4590` | view |

`midnight_isCallbackAllowed` returns `callback != 0 && maxMakeOfferSize != 0 && (!buy || maxBuyTick != 0) && strategyKey(buy).maxAmount != 0 && marketKey(buy).maxAmount != 0`. It reads `maxAmount`, not the current capacity. A zero callback is always `false`, so an offer that names no callback (and would therefore never reach `fundFill`) cannot be ratified.

## Admin configuration

| Function | Access | Notes |
|---|---|---|
| `setMidnightMarketConfig(market, maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor, maxMakeOfferSize)` | admin | Sets the one config of the market: the price, fee and loss bounds that takes and maker fills share, and `maxMakeOfferSize`. Takes the full `Market` struct, which must name this controller's Midnight and exist on it (`toMarket(marketId)` equal to it), and caches its `loanToken` and `maturity`. `minSellTick != 0` onboards the market for taking. `maxMakeOfferSize` is the make-enabled flag (`!= 0`) and caps the assets of each **fill**, not each offer. Every call restates the whole config. A config change prepared while making was enabled carries the old `maxMakeOfferSize`, so if `disableMidnightMake` ran since, it enables making again when it executes; read the market's current `maxMakeOfferSize` at execution and pass zero if making was disabled. Emits `MidnightMarketConfigSet`. |
| `disableMidnightMake(marketId)` | `FREEZER` | Sets `maxMakeOfferSize` to zero and changes nothing else. Reads nothing from Midnight. Emits `MidnightMakeDisabled(marketId)`. |
| `setMidnightRatifierAuthorization(ratifier, authorized)` | admin | `midnight.setIsAuthorized(ratifier, authorized, proxy)`. A zero ratifier is rejected (`FC/ratifier-zero-address`). This is a blanket grant; see [Ratifier authorization is a blanket grant](#ratifier-authorization-is-a-blanket-grant). Keep exactly one ratifier authorized per proxy; see [One ratifier per proxy](#kill-switches-and-runbook). |
| `cancelMidnightOfferGroup(group)` | `RELAYER` or `FREEZER` | `setConsumed(group, type(uint128).max, proxy)`. This retires the group for good. Because the group's consumed amount is then the `uint128` maximum, even a zero-unit take of an offer with a smaller `maxUnits` (or `maxAssets`, when set) reverts in Midnight before any callback. An offer capped at the `uint128` maximum still reaches its callback at zero units, and the dust rule makes that a no-op. |

Groups are operator-managed: any number and any id, per market or across markets. Retiring a group is permanent. Midnight counts consumption per group, so offers that share a group share its capacity and are cancelled together. Midnight keeps no list of groups and a cancel needs the exact id, so keep every group id the quoter has used on record off-chain. To make a market one-directional, leave the other direction's strategy keys unset. Midnight accepts a cancel for any group id, so a compromised canceller (`RELAYER` or `FREEZER`) can retire any group the quoter uses, including new ones; revoke the compromised role before quoting in new groups.

### Enabling maker mode

The market must already be onboarded for taking: `setMidnightMarketConfig` with a non-zero `minSellTick`, and `LIMIT_MIDNIGHT_BUY`, `LIMIT_MIDNIGHT_SELL` and `LIMIT_MIDNIGHT_REDEEM` set for it (see [Rate-limit model](#rate-limit-model)). `midnight_isCallbackAllowed` stays false for a direction whose market key is unset. Then, in this order:

1. Deploy the ratifier and the funding strategy from the periphery, both bound to this proxy and this controller. Before authorizing anything, review the deployed code against the audited source, check the strategy against the [conformance rules](#strategy-conformance-rules), and run the opcode scan over the ratifier's runtime (see [Ratifier authorization is a blanket grant](#ratifier-authorization-is-a-blanket-grant)).
2. `setMidnightMarketConfig` again with the same bounds and a non-zero `maxMakeOfferSize`, only if the onboarding call did not already set it: nothing fills before step 3, because `midnight_isCallbackAllowed` and `midnight_fundFill` both need the strategy key, so one call per market is enough.
3. Set `LIMIT_MIDNIGHT_STRATEGY_BUY` and `LIMIT_MIDNIGHT_STRATEGY_SELL` for each strategy and direction the market's offers may use. A direction whose strategy keys stay unset stays closed.
4. Grant the ratifier's roles. The quoter gets `QUOTER_ROLE` at deployment, through the constructor's `quoter_` argument, or in the spell. The spell grants `FREEZER_ROLE` and `MANAGER_ROLE` to keys other than the quoter. With these grants in the spell, the ratifier has a freezer before it is authorized.
5. `setMidnightRatifierAuthorization(ratifier, true)` **last**, once everything above is in place, the ratifier's roles included. This is the step that makes resting offers fillable.

## Rate-limit model

Per market, shared by takes and maker fills (`RateLimitHelpers.makeBytes32Key(id, marketId)`):

| Id | Spent by |
|---|---|
| `LIMIT_MIDNIGHT_BUY` | relayer take-buys **and** every maker buy fill |
| `LIMIT_MIDNIGHT_SELL` | relayer take-sells **and** every maker sell fill |
| `LIMIT_MIDNIGHT_REDEEM` | redeem only |

Per market and per strategy, maker fills only (`RateLimitHelpers.makeAddressBytes32Key(id, strategy, marketId)`):

| Id | Spent by |
|---|---|
| `LIMIT_MIDNIGHT_STRATEGY_BUY` | maker buy fills funded by that strategy |
| `LIMIT_MIDNIGHT_STRATEGY_SELL` | maker sell fills funded by that strategy |

The ids are `MidnightLib` constants (`keccak256("LIMIT_MIDNIGHT_*")`). The keys are `keccak256(abi.encode(id, marketId))` and `keccak256(abi.encode(id, strategy, marketId))`, the same as on the diamond.

- The two strategy keys **are** the strategy whitelist, per market and per direction. A non-zero `maxAmount` means the strategy is onboarded for that (market, direction). There is no separate mapping, setter, event or role. Governance onboards a strategy by setting its key and offboards it by zeroing the key.
- A maker fill spends exactly two keys: first its strategy key, then the market key, both for the fill's direction. A take spends only its market key. No path spends a key of the other direction, and no path credits any key back. Capacity returns only through each key's own slope.
- `midnight_fundFill` from an address with no strategy key for that (market, direction) reverts `RateLimits/zero-maxAmount` before any state change or transfer.
- `maxAmount == type(uint256).max` means **unlimited**, which is the `RateLimits` special case: the key is never debited and tracks nothing. This is intended configuration that governance may choose deliberately. Such a key still counts as set, so the strategy is onboarded and passes the key check of `midnight_isCallbackAllowed`. The strategy is then bounded per fill by `maxMakeOfferSize` and cumulatively by the market key for the direction alone. Keep the market **buy** key finite: that is the intended configuration. An unlimited market buy key is still technically possible, but together with a faulty strategy it exposes the proxy's whole loan-token balance, because fabricated buys are then bounded only by that balance.
- Maker and taker flow share the market keys. Any taker willing to trade at policy prices can use up that capacity, and a fill that exceeds any key on its path reverts the taker's transaction, not ours. If a direction's key is nearly spent, retire that direction's groups instead of leaving the book to fail.

## `midnight_fundFill`

The call is roleless on purpose: the caller's funded strategy key is the authorization. `msg.sender` is the strategy. The checks run in this order:

1. `maxMakeOfferSize != 0` (`MidnightLib/make-not-enabled`), `assets != 0` (`zero-assets`), `units != 0` (`zero-units`) and `assets <= maxMakeOfferSize` (`offer-size-too-large`).
2. **Buy:** the live `continuousFee <= ceiling` (`continuous-fee-too-high`), checked before `lossFactor <= maxLossFactor` (`loss-factor-too-high`). Then `assets * WAD <= units * bound` (`fill-price-too-high`), where `bound` is the lower of `tickToPrice(maxBuyTick)` and the `minBuyYield` price with the fee priced at that live `continuousFee`, the same read a take prices with. `pendingFee` is accepted and ignored. A `maxBuyTick` of `0` refuses every maker buy, because `tickToPrice(0) == 0`. The maker path has no separate `buy-not-enabled` check.
3. **Sell:** `assets * WAD >= units * floor` (`fill-price-too-low`), where `floor` is the higher of `tickToPrice(minSellTick)` and the `maxSellYield` floor. That floor uses the fee per unit `min(pendingFee * WAD / units, carried * WAD / creditPost)`, read from the proxy's position after the fill. A reported fee can therefore only tighten the floor. After the price check, the proxy must hold no debt (`debt-not-zero`).
4. Debit the strategy key, then the market key, both by `assets`.
5. **Buy only:** transfer `loanToken` from the proxy to `msg.sender` through `ERC20Lib.transfer`.
6. Emit `MidnightFillFunded(marketId, strategy, buy, assets, units)`.

**Full and near-full exits.** A full exit (`creditPost == 0`) has no carried fee to read, so it prices at the zero-fee yield floor, not at par. A near-full exit whose carried fee rounds to zero gets the same floor, because Midnight rounds the fee a fill sheds up, so a position left with dust credit can carry no fee. Both cases only tighten the floor. A quoter that prices such an exit at the fee-adjusted floor will see the taker's fill revert with `fill-price-too-low`.

**Dust callbacks.** The strategy returns success without calling `fundFill` when `buyerAssets == 0` on a buy, or when `units == 0` on a sell or a zero-unit take. Nothing is metered and nothing moves. A zero-asset buy gives the proxy free dust credit. This is a conformance rule: `fundFill` refuses both cases, so a strategy that called it would fail an unrelated taker's transaction.

**Sell dust.** A sell whose assets round to zero (`units > 0`, `sellerAssets == 0`) reverts by design with `MidnightLib/zero-assets`; strategies do not short-circuit it. Midnight has already taken the proxy's units when `onSell` runs, so a short-circuit would hand those units away with no floor and no meter; the revert costs only the dust taker.

## Strategy conformance rules

Strategies are trusted code. The controller does not cross-check what a strategy reports; it bounds it with the price gates and the keys. Every strategy must:

- be callable only by the Midnight singleton;
- check that the buyer, seller or receiver it is told about is the proxy;
- call `fundFill` with the callback's direction and exactly Midnight's `assets`, `units` and pending-fee value;
- leave no allowance behind and no balance in the **strategy** itself;
- never take amounts, venues or slippage parameters from callback data;
- follow the dust rules above: short-circuit a zero-asset buy and a zero-unit sell, and pass a sell whose assets round to zero to `fundFill`, which reverts by design; strategies do not short-circuit it.

**Pass-through strategies (phase 2)**, such as `ProxyBasicFillStrategy`, hold no role.

**Operator-role strategies (phase 3)** source liquidity inside `onBuy`, for example `withdrawAave` then `midnight_fundFill`, and hold `RELAYER` on this controller. Midnight pays a sell's proceeds to the proxy before `onSell`, so a sell strategy can also redeploy them in the same callback; the periphery proves this with configuration only. Each must be immutable, run one hardcoded sourcing sequence, and be audited on its own. Governance onboards one per (market, direction) by setting its strategy key, and the FC admin grants it `RELAYER`. To offboard it, zero its keys and have the FC admin revoke `RELAYER`. The FC `FREEZER` can also call `removeRelayer`. Sourcing may leave residual dust **on the proxy**, or run a cleanup step after `fundFill`. Either way, the strategy itself must end empty. No core change is needed: the fork suite fills a real maker buy from the live Aave V3 USDC reserve on Base, and from an ERC4626 vault, with deployment and configuration only.

`RELAYER` gives the strategy the whole relayer surface, not only the sequence its code runs. There are two separate bounds:

- **Role surface:** every rate limit `RELAYER` can spend. Only revoking the role ends it.
- **Per-fill outflow:** at most min(`maxMakeOfferSize`, its strategy key, the market key for the direction), through `fundFill`, and cumulative across repeated fills. A venue key binds only the amount the sourcing sequence sources, not what the proxy already holds idle.

**Phase 3 design considerations.** These describe risks, not restrictions. Which strategies phase 3 builds has not been decided.

- The taker chooses the timing and size of a fill, so sourcing inside `onBuy` runs whenever the taker wants. Sourcing with price impact can be sandwiched within the same transaction. A slippage bound derived from a spot price the taker can move protects nothing.
- Sourcing paths share venue rate limits (for example, the Aave or ERC4626 withdraw keys) with human relayers, and a taker can use up that capacity.
- `ForeignController` has no USDS mint integration. USDS minting exists only on mainnet (`MainnetController` and the diamond), and `MainnetController` has no Midnight integration, so mint-based sourcing is diamond-only.
- The periphery's conformance test base covers pass-through strategies. A variant that runs role-holding strategies against the real hosts is future work.

## Trust model

A keyed strategy can call `midnight_fundFill` with no fill behind it. Such a call involves no offer, group, ratifier or `take`. The buy branch pays `msg.sender`, and the price bound only ties `assets` to `units`, which the caller chooses. A fabricated buy can therefore draw up to the lower of the strategy buy key and the market buy key, plus whatever their slopes refill, repeated in chunks of up to `maxMakeOfferSize`. If the market buy key is also `type(uint256).max`, fabricated buys are bounded only by the proxy's loan-token balance, which is why the market buy key is kept finite. A fabricated sell pays nothing and restores nothing; it only spends the sell budgets. A ratifier freeze does not stop this, and neither does `cancelMidnightOfferGroup`. Zeroing a strategy's keys stops that strategy. Zeroing `maxMakeOfferSize` (`disableMidnightMake` by the FC `FREEZER`, or the admin setter) stops every strategy on that market, fabricated `fundFill` calls included, because it is `fundFill`'s first check. Callers without a key, genuine fills and takers cannot move funds outside policy.

## Kill switches and runbook

**Ratifier freeze.** The ratifier's `freeze()`, held by the ratifier's own freezer role, is the maker kill switch on both hosts. It stops new ratified maker fills in both directions. Only the ratifier admin can `unfreeze`. The ratifier freeze stops resting offers in every group, because Midnight calls `isRatified` on every fill; zeroing `maxMakeOfferSize` stops one market; the rate limits and `maxMakeOfferSize` stay the hard caps. It does not stop a keyed strategy calling `fundFill` directly. Zeroing a strategy's keys stops that strategy; zeroing `maxMakeOfferSize` (`disableMidnightMake` by the FC `FREEZER`, or the admin setter) also stops fabricated `fundFill` calls, because it is `fundFill`'s first check.

**One ratifier per proxy.** Keep exactly one ratifier authorized for each proxy. Each host, and each chain, has its own ratifier deployment, bound to one proxy and one controller, and a `freeze()` stops only the ratifier it is called on. To change ratifier logic, deploy a new ratifier and swap the authorization: grant the new ratifier its `FREEZER_ROLE` and `MANAGER_ROLE` (and `QUOTER_ROLE`, unless its deployment granted it), authorize it, and deauthorize the old one with `setMidnightRatifierAuthorization(old, false)` in the same governance action. Offers signed for the old ratifier die with its deauthorization, because the ratifier address is part of the offer. If more than one ratifier is ever authorized for the proxy, freeze every one of them.

| Lever | Scope | Who |
|---|---|---|
| ratifier `freeze()` | every market, both directions, until `unfreeze` | ratifier freezer |
| `disableMidnightMake(marketId)` | one market, both directions, every strategy: `midnight_isCallbackAllowed` turns false, so the ratifier stops ratifying, and every `fundFill` on the market, fabricated calls included, reverts `make-not-enabled`; reads nothing from Midnight | FC `FREEZER` |
| `cancelMidnightOfferGroup(group)` | every offer in that group, on every market, irreversible | FC `FREEZER` or `RELAYER` |
| `removeRelayer(strategy)` | an operator-role strategy's sourcing path | FC `FREEZER` |
| zero `LIMIT_MIDNIGHT_STRATEGY_*` | one strategy, one market and direction, its fabricated `fundFill` calls included | RateLimits admin |
| `setMidnightRatifierAuthorization(ratifier, false)` | every resting offer naming that ratifier | admin |

Setting `maxBuyTick` to zero closes entry: `midnight_isCallbackAllowed` then returns false for buys, so the ratifier refuses buy offers, resting ones included, and maker buy fills, fabricated `fundFill` calls included, revert with `fill-price-too-high`.

**Runbook.**

1. Freeze the proxy's ratifier (every ratifier authorized for the proxy, if more than one is).
2. The FC `FREEZER` calls `disableMidnightMake` on each affected market, which also halts fabricated `fundFill` calls there, then cancels the groups the quoter uses, and calls `removeRelayer` for operator-role strategies. ALM has no proxy freeze, and removing relayers does not stop maker fills, because pass-through strategies hold no role. A compromised quoter can sign offers in groups nobody has seen, so cancelling the groups the quoter uses does not retire them; the ratifier freezer calls `removeQuoter` on that key before any `unfreeze()`.
3. Governance zeroes the strategy keys and revokes operator roles.
4. After an incident, check pending spells that set this market's config; if one executes, call the lever again.

**Strategy compromised.** A ratifier freeze does not stop a keyed strategy calling `fundFill` directly, so the order is different:

1. The FC `FREEZER` calls `disableMidnightMake(marketId)` on every market the strategy is keyed for, one call per market. This stops fabricated `fundFill` calls, which the ratifier freeze does not. It also stops every other strategy on those markets. Strategy keys are hashes in `RateLimits` and cannot be listed on-chain, so keep each strategy's keyed markets on record off-chain; if the list is uncertain, disable every market whose latest `MidnightMarketConfigSet` has a non-zero `maxMakeOfferSize` and no later `MidnightMakeDisabled`. Each call needs only the `marketId`.
2. Governance zeroes the strategy's `LIMIT_MIDNIGHT_STRATEGY_*` keys.
3. For an operator-role strategy, the FC `FREEZER` revokes its `RELAYER` role with `removeRelayer`.
4. After an incident, check pending spells that set this market's config; if one executes, call the lever again.

Once the strategy's keys are zero, the admin can restore `maxMakeOfferSize` for the other strategies on those markets with `setMidnightMarketConfig`. Every lever is visible in the mempool, and a compromised strategy can draw the remaining buy budget in front of it, so send the freezer's and governance's transactions through a private relay.

Revoking the controller's `CONTROLLER` role on the ALMProxy is not a maker kill switch. It stops maker buys, but not maker sells, because the sell branch of `fundFill` makes no proxy call and Midnight pays the proxy directly. It also blocks `cancelMidnightOfferGroup` and `setMidnightRatifierAuthorization`, which reach the venue through the proxy, so after it the `FREEZER`'s cancel reverts too and `disableMidnightMake` is its Midnight lever that still works.

## Ratifier authorization is a blanket grant

Midnight gates maker fills on `isAuthorized[proxy][ratifier]`, and that is one flat mapping. The same entry also lets the grantee call `withdraw`, `repay`, `supplyCollateral`, `withdrawCollateral`, `setConsumed` and `setIsAuthorized` on the proxy's behalf. `setMidnightRatifierAuthorization(ratifier, true)` therefore hands the ratifier the proxy's whole position on the venue, and there is no narrower grant to ask for.

Authorize only a reviewed, immutable contract that cannot use the grant: no upgrade or admin path that reaches the singleton, and a deployed runtime with no `CALL`, `CALLCODE`, `DELEGATECALL`, `CREATE`, `CREATE2` or `SELFDESTRUCT` opcode. The ratifier ships from the periphery, so the opcode scan of its deployed runtime is a precondition on the authorizing spell, not something this repository's tests can assert. Monitor Midnight's `SetIsAuthorized` events with `onBehalf` equal to the proxy, not only the mapping: the grant includes `setIsAuthorized`, so an authorized contract could add entries of its own, and revoking the ratifier does not clear them.

## Divergences from the diamond `MidnightFacet`

The two periphery-facing selectors, the `fundFill` checks and their order, the view semantics, the key ids and encodings, and the maker events are identical on both hosts. The rest differs by convention:

- **Roles.** Admin maps to `DEFAULT_ADMIN_ROLE` on both hosts, and FC `RELAYER` maps to the diamond `ALLOCATOR_ROLE`. Both hosts let a freezer disable making on a market and cancel offer groups: FC `FREEZER` here, and on the diamond `MIDNIGHT_FREEZER_ROLE` in `AccessControls`. The role ids differ: this controller's is `keccak256("FREEZER")` and the diamond's is `0x734f97facdc17c5a0364162ede289ef3fc7501314999442287d4c3f97235a585`, so a spell must not reuse one host's id on the other.
  - **This controller:** The Midnight freezer (`FREEZER`) can disable making on a market with `disableMidnightMake(marketId)`, which sets `maxMakeOfferSize` to zero and changes nothing else; it reads nothing from Midnight and stops every strategy on that market, fabricated `fundFill` calls included. Only the admin can enable making again, through the market config setter. The Midnight freezer (`FREEZER`) can also cancel an offer group, which retires the group permanently.
  - **Diamond:** The Midnight freezer (`MIDNIGHT_FREEZER_ROLE` in `AccessControls`) can disable making on a market with `disableMake(marketId)`, which sets `maxMakeOfferSize` to zero and changes nothing else; it reads nothing from Midnight and stops every strategy on that market, fabricated `fundFill` calls included. Only the admin can enable making again, through the market config setter. The Midnight freezer (`MIDNIGHT_FREEZER_ROLE` in `AccessControls`) can also cancel an offer group, which retires the group permanently.
- **Operator roles.** The FC admin grants `RELAYER` and the FC freezer can `removeRelayer`. On the diamond, the `AccessControls` allocator role admin grants and revokes `ALLOCATOR_ROLE`.
- **Market config.** The setter is `setMidnightMarketConfig` here and `setMarketConfig` on the diamond. Both take the full `Market` struct and cache maturity as a `uint64`. The config getter is `midnightMarketConfigs(marketId)` here and `getMarketConfig(marketId)` on the diamond; both return the same struct.
- **Venue check.** The setter's last check calls `toMarket(marketId)`, which reverts `MarketNotCreated()` for a market never created on both hosts. Here it then requires `toId` of the returned market to equal `marketId`; the diamond requires the returned maturity to equal the one passed. Both `market-mismatch` branches hold by construction, because `toMarket` decodes the market deployed at the address the id commits to.
- **Key getters.** The diamond exposes strategy key getters. Here the ids are `MidnightLib` constants and keys are built with `RateLimitHelpers`.
- **Error prefixes.** Errors here are `MidnightLib/...` and `FC/...`; on the diamond they are `MidnightFacet/...`. The suffixes match for every maker check except the zero ratifier (`FC/ratifier-zero-address` vs `MidnightFacet/zero-ratifier`) and the transfer (`ERC20Lib/transfer-failed` vs `MidnightFacet/transfer-failed`). An unset key reverts `RateLimits/zero-maxAmount` on both.
- **Transfer return data.** `ERC20Lib.transfer` accepts empty return data or a first word decoding to `true` for any return of 32 bytes or more. The diamond accepts empty return data or exactly 32 bytes decoding to `true`. The two differ only for a non-standard token that returns more than 32 bytes.
- **Setter guards and events.** The Midnight config setters and `disableMidnightMake` are not `nonReentrant` here, while on the diamond the setters and `disableMake` are. The setters are admin-only on both hosts, and their only state-changing external call is the ratifier authorization `doCall`; the make lever is freezer-only on both hosts and makes no external call. The diamond emits taker events (`MidnightBuy`, `MidnightSell`, `MidnightRedeem`); this controller emits none.
- **Full exit with an oversized fee.** This controller returns the zero fee rate for a full exit before it divides `pendingFee` by `units`. The diamond divides first, so a full exit reporting a `pendingFee` above about `1.16e59` reverts there and passes here. Midnight's fee is a `uint128`, and a conforming strategy forwards it unchanged, so the case is unreachable.
- **USDS mint.** Not available here. See the phase 3 considerations above.
- **Naming.** Only the two periphery-facing functions carry the `midnight_` prefix. Every other Midnight function uses the controller's own naming (`buyMidnight`, `setMidnightMarketConfig`, ...). On the diamond, every Midnight selector is wired as `midnight_*`.
