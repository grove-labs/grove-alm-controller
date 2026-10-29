# Morpho Midnight on ForeignController

`ForeignController` integrates the Morpho Midnight singleton (`morpho-org/midnight @ 70607569`) for the ALMProxy as a lender only. It supports two modes:

- **Taker mode** (`RELAYER`): `buyMidnight`, `sellMidnight` and `redeemMidnight` take other makers' offers and redeem at maturity.
- **Maker mode**: the proxy publishes its own offers. A third party fills them by calling `midnight.take` directly, so none of our transactions is in the call stack. Two immutable periphery contracts (`grove-morpho-midnight-periphery`) act for the controller in that stack. A **ratifier** decides whether an offer is live. A **funding strategy**, named as the offer's `callback`, calls `midnight_fundFill` from inside `onBuy` / `onSell`.

The logic lives in `MidnightLib`, and the controller holds the configuration and the role checks. The same periphery also serves the diamond-pau `MidnightFacet`, through the same three selectors with the same semantics.

## Periphery-facing surface

| Function | Selector | Access |
|---|---|---|
| `midnight_fundFill(bytes32 marketId, bool buy, uint256 assets, uint256 units, uint256 pendingFee)` | `0xfb9e2099` | roleless, `nonReentrant` |
| `midnight_isCallbackAllowed(bytes32 marketId, address callback, bool buy) returns (bool)` | `0x5c0f4590` | view |
| `midnight_getDesignatedGroups(bytes32 marketId) returns (bytes32 buyGroup, bytes32 sellGroup)` | `0x87d2a293` | view |

`midnight_isCallbackAllowed` returns `callback != 0 && maxOfferSize != 0 && strategyKey(buy).maxAmount != 0 && marketKey(buy).maxAmount != 0`. It reads `maxAmount`, not the current capacity. A zero callback is always `false`, so an offer that names no callback (and would therefore never reach `fundFill`) cannot be ratified.

## Admin configuration

| Function | Access | Notes |
|---|---|---|
| `setMidnightMarketConfig(marketId, maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor)` | admin | Onboards the market (`minSellTick != 0`) for taking and sets the price, fee and loss bounds that maker fills use too. Preserves the make config. |
| `setMidnightMakeConfig(marketId, maxOfferSize)` | admin; `FREEZER` may set `0` only | Needs a market onboarded for taking. Caches `loanToken` and `maturity` from `toMarket`. `maxOfferSize` is the make-enabled flag (`!= 0`) and caps the assets of each **fill**, not each offer. |
| `setMidnightGroups(marketId, buyGroup, sellGroup)` | admin | Both groups must be non-zero and distinct (`FC/invalid-groups`). |
| `setMidnightRatifierAuthorization(ratifier, authorized)` | admin | `midnight.setIsAuthorized(ratifier, authorized, proxy)`. A zero ratifier is rejected (`FC/ratifier-zero-address`). |
| `cancelMidnightOfferGroup(group)` | `RELAYER` or `FREEZER` | `setConsumed(group, type(uint128).max, proxy)`. This retires the group for good, and even a zero-unit take of an offer in it then reverts `ConsumedUnits()`. |

Group rules: one group per direction per market. To make a market one-directional, leave the other direction's strategy keys unset. Never reuse a group on another market, because cancelling it would retire both books. This is an operational rule, not a code check.

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
- `maxAmount == type(uint256).max` means **unlimited**, which is the `RateLimits` special case: the key is never debited and tracks nothing. This is intended configuration that governance may choose deliberately. Such a key still counts as set, so the strategy is onboarded and `midnight_isCallbackAllowed` holds. The strategy is then bounded per fill by `maxOfferSize` and cumulatively by the market key for the direction alone.
- Maker and taker flow share the market keys. Any taker willing to trade at policy prices can use up that capacity, and a fill that exceeds any key on its path reverts the taker's transaction, not ours. If a direction's key is nearly spent, retire its group instead of leaving the book to fail.

## `midnight_fundFill`

The call is roleless on purpose: the caller's funded strategy key is the authorization. `msg.sender` is the strategy. The checks run in this order:

1. `maxOfferSize != 0` (`MidnightLib/make-not-enabled`), `assets != 0` (`zero-assets`), `units != 0` (`zero-units`) and `assets <= maxOfferSize` (`offer-size-too-large`).
2. **Buy:** the live `continuousFee <= ceiling` (`continuous-fee-too-high`), checked before `lossFactor <= maxLossFactor` (`loss-factor-too-high`). Then `assets * WAD <= units * bound` (`fill-price-too-high`), where `bound` is the lower of `tickToPrice(maxBuyTick)` and the `minBuyYield` price with the fee priced at the configured ceiling. `pendingFee` is accepted and ignored. A `maxBuyTick` of `0` refuses every maker buy, because `tickToPrice(0) == 0`. The maker path has no separate `buy-not-enabled` check.
3. **Sell:** `assets * WAD >= units * floor` (`fill-price-too-low`), where `floor` is the higher of `tickToPrice(minSellTick)` and the `maxSellYield` floor. That floor uses the fee per unit `min(pendingFee * WAD / units, carried * WAD / creditPost)`, read from the proxy's position after the fill. A reported fee can therefore only tighten the floor. After the price check, the proxy must hold no debt (`debt-not-zero`).
4. Debit the strategy key, then the market key, both by `assets`.
5. **Buy only:** transfer `loanToken` from the proxy to `msg.sender` through `ERC20Lib.transfer`.
6. Emit `MidnightFillFunded(marketId, strategy, buy, assets, units)`.

**Full and near-full exits.** A full exit (`creditPost == 0`) has no carried fee to read, so it prices at the zero-fee yield floor, not at par. A near-full exit whose carried fee rounds to zero gets the same floor, because Midnight rounds the fee a fill sheds up, so a position left with dust credit can carry no fee. Both cases only tighten the floor. A quoter that prices such an exit at the fee-adjusted floor will see the taker's fill revert with `fill-price-too-low`.

**Dust callbacks.** The strategy returns success without calling `fundFill` when `buyerAssets == 0` on a buy, or when `units == 0` on a sell or a zero-unit take. Nothing is metered and nothing moves. A zero-asset buy gives the proxy free dust credit. This is a conformance rule: `fundFill` refuses both cases, so a strategy that called it would fail an unrelated taker's transaction.

## Strategy conformance rules

Strategies are trusted code. The controller does not cross-check what a strategy reports; it bounds it with the price gates and the keys. Every strategy must:

- be callable only by the Midnight singleton;
- check that the buyer, seller or receiver it is told about is the proxy;
- call `fundFill` with the callback's direction and exactly Midnight's `assets`, `units` and pending-fee value;
- leave no allowance behind and no balance in the **strategy** itself;
- never take amounts, venues or slippage parameters from callback data;
- follow the dust rule above.

**Pass-through strategies (phase 2)**, such as `ProxyBasicFillStrategy`, hold no role.

**Operator-role strategies (phase 3)** source liquidity inside `onBuy`, for example `withdrawAave` then `midnight_fundFill`, and hold `RELAYER` on this controller. Each must be immutable, run one hardcoded sourcing sequence, and be audited on its own. Governance onboards one per (market, direction) by setting its strategy key, and the FC admin grants it `RELAYER`. To offboard it, zero its keys and have the FC admin revoke `RELAYER`. The FC `FREEZER` can also call `removeRelayer`. Sourcing may leave residual dust **on the proxy**, or run a cleanup step after `fundFill`. Either way, the strategy itself must end empty. No core change is needed: the fork suite fills a real maker buy from the live Aave V3 USDC reserve on Base, and from an ERC4626 vault, with deployment and configuration only.

`RELAYER` gives the strategy the whole relayer surface, not only the sequence its code runs. Its code and the keys on its path are what bound it. Per fill, its exposure is at most the lowest of its strategy key, the market key for the direction, and each venue key its sourcing sequence touches.

**Phase 3 design considerations.** These describe risks, not restrictions. Which strategies phase 3 builds has not been decided.

- The taker chooses the timing and size of a fill, so sourcing inside `onBuy` runs whenever the taker wants. Sourcing with price impact can be sandwiched within the same transaction. A slippage bound derived from a spot price the taker can move protects nothing.
- Sourcing paths share venue rate limits (for example, the Aave or ERC4626 withdraw keys) with human relayers, and a taker can use up that capacity.
- `ForeignController` has no USDS mint integration. USDS minting exists only on mainnet (`MainnetController` and the diamond), and `MainnetController` has no Midnight integration, so mint-based sourcing is diamond-only.
- The periphery's conformance test base covers pass-through strategies. A variant that runs role-holding strategies against the real hosts is future work.

## Trust model

A keyed strategy can call `midnight_fundFill` with no fill behind it. Such a call involves no offer, group, ratifier or `take`. The buy branch pays `msg.sender`, and the price bound only ties `assets` to `units`, which the caller chooses. A fabricated buy can therefore draw up to the lower of the strategy buy key and the market buy key, plus whatever their slopes refill, repeated in chunks of up to `maxOfferSize`. A fabricated sell pays nothing and restores nothing; it only spends the sell budgets. A ratifier freeze does not stop this, and neither does `cancelMidnightOfferGroup`. Zeroing the strategy's keys does. Callers without a key, genuine fills and takers cannot move funds outside policy.

## Kill switches and runbook

**Ratifier freeze.** The ratifier's `freeze()`, held by the ratifier's own freezer role, is the maker kill switch on both hosts. It stops new ratified maker fills in both directions. Only the ratifier admin can `unfreeze`. It does not stop a keyed strategy calling `fundFill` directly; only zeroing its strategy keys does.

| Lever | Scope | Who |
|---|---|---|
| ratifier `freeze()` | every market, both directions, until `unfreeze` | ratifier freezer |
| `setMidnightMakeConfig(marketId, 0)` | one market, both directions: `midnight_isCallbackAllowed` turns false, so the ratifier stops ratifying, and a racing fill reverts `make-not-enabled` | FC `FREEZER` or admin |
| `cancelMidnightOfferGroup(group)` | one direction on one market, irreversible | FC `FREEZER` or `RELAYER` |
| `removeRelayer(strategy)` | an operator-role strategy's sourcing path | FC `FREEZER` |
| zero `LIMIT_MIDNIGHT_STRATEGY_*` | one strategy, one market and direction, fabricated `fundFill` calls included | RateLimits admin |
| `setMidnightRatifierAuthorization(ratifier, false)` | every resting offer naming that ratifier | admin |

**Runbook.**

1. Freeze the ratifier.
2. The FC `FREEZER` zeroes `maxOfferSize` on each affected market, cancels the designated groups, and calls `removeRelayer` for operator-role strategies. ALM has no proxy freeze, and removing relayers does not stop maker fills, because pass-through strategies hold no role.
3. Governance zeroes the strategy keys and revokes operator roles.

Revoking the controller's `CONTROLLER` role on the ALMProxy is not a maker kill switch. It stops maker buys, but not maker sells, because the sell branch of `fundFill` makes no proxy call and Midnight pays the proxy directly. It also blocks `cancelMidnightOfferGroup` and `setMidnightRatifierAuthorization`, which reach the venue through the proxy.

## Divergences from the diamond `MidnightFacet`

The three periphery-facing selectors, the `fundFill` checks and their order, the view semantics, the key ids and encodings, and the maker events are identical on both hosts. The rest differs by convention:

- **Roles.** Admin maps to `DEFAULT_ADMIN_ROLE` on both hosts, and FC `RELAYER` maps to the diamond `ALLOCATOR_ROLE`. FC `FREEZER` has no diamond equivalent, so only the ALM lets a freezer zero `maxOfferSize`; on the diamond that is admin-only.
- **Group cancels.** `cancelMidnightOfferGroup` is open to `RELAYER` and `FREEZER` here. The diamond's `cancelOfferGroup` is `ALLOCATOR_ROLE` only, so only on the ALM can a freezer retire a book without a relayer.
- **Operator roles.** The FC admin grants `RELAYER` and the FC freezer can `removeRelayer`. On the diamond, the `AccessControls` allocator role admin grants and revokes `ALLOCATOR_ROLE`.
- **Make config.** `setMidnightMakeConfig` takes a `marketId` here and the full `Market` struct on the diamond. The cached maturity is a `uint48` here and a `uint64` on the diamond. Midnight caps maturity at 100 years, so neither width binds.
- **Key getters.** The diamond exposes strategy key getters. Here the ids are `MidnightLib` constants and keys are built with `RateLimitHelpers`.
- **Error prefixes.** Errors here are `MidnightLib/...` and `FC/...`; on the diamond they are `MidnightFacet/...`. The suffixes match for every maker check except the zero ratifier (`FC/ratifier-zero-address` vs `MidnightFacet/zero-ratifier`) and the transfer (`ERC20Lib/transfer-failed` vs `MidnightFacet/transfer-failed`). An unset key reverts `RateLimits/zero-maxAmount` on both.
- **Transfer return data.** `ERC20Lib.transfer` accepts empty return data or a first word decoding to `true` for any return of 32 bytes or more. The diamond requires exactly 32 bytes. The two differ only for a non-standard token that returns more than 32 bytes.
- **Setter guards and events.** The Midnight config setters are not `nonReentrant` here, while on the diamond they are. They are admin-only on both hosts, and their only external call is the ratifier authorization `doCall`. The diamond emits taker events (`MidnightBuy`, `MidnightSell`, `MidnightRedeem`); this controller emits none.
- **Full exit with an oversized fee.** This controller returns the zero fee rate for a full exit before it divides `pendingFee` by `units`. The diamond divides first, so a full exit reporting a `pendingFee` above about `1.16e59` reverts there and passes here. Midnight's fee is a `uint128`, and a conforming strategy forwards it unchanged, so the case is unreachable.
- **USDS mint.** Not available here. See the phase 3 considerations above.
- **Naming.** Only the three periphery-facing functions carry the `midnight_` prefix. Every other Midnight function uses the controller's own naming (`buyMidnight`, `setMidnightGroups`, ...). On the diamond, every Midnight selector is wired as `midnight_*`.
