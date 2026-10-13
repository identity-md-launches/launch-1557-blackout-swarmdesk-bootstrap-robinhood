# BLACKOUT SwarmDesk bootstrap: test and launch notes

This submission changes tests only. Application source, compiler settings, dependencies, and
the twelve approved constructor words are unchanged. No transactions were broadcast and no
production address is claimed by these tests.

## Exact bootstrap

`SwarmDeskBootstrap.t.sol` deploys exactly one application in its local bootstrap rehearsal,
through the factory fixture at `0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e`, on chain ID 4663.
It independently encodes all twelve approved words, requires the creation-code hash
`0x65968358bcf87aa8839b8bce6b2d339493deac3f77d75a3ff0b3ad4f35955745`, and records the resulting
**local test address** in the test log. The local coordinates `(1, 0)` are fixture coordinates,
not reserved production launch numbers or a production address prediction.

The state-diff check requires one CREATE, zero deployment value, and no constructor external
calls. The deployed Desk must be unbound, have both launch numbers and indices zero, and retain
GAME_CONFIG_HASH `0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3`,
heartbeat 200 bps, and heartbeat cap 1e18. It also checks the attester, transport addresses,
payment asset, question/body commitments, own EIP-712 domain, runtime size, and forbidden opcodes.

The existing JS bootstrap checks independently regenerate the constructor words using
`tools/swarm_constructor_args.mjs`, `docs/oracle-v37/oracle-config.json`, and
`docs/swarm-bootstrap-v313/binding.json`.

## Added failure and property coverage

| Suite | What it checks |
| --- | --- |
| `SwarmDeskBootstrap.t.sol` | Zero constructor words, duplicate endpoints/questions, packed-field widths and reserved bits, invalid heartbeat/window/price/chain policy, nonpayable construction, invalid bind coordinates, all unbound action gates. |
| `SwarmDeskBinding.t.sol` | Mutation of each frozen game field and creation proof, wrong coordinates/factory/Params, missing dependency code, runtime-identical nonfactory look-alikes, permissionless binding at index 7 across separate launches, atomic failures and one-time binding. |
| `SwarmDeskAdversarial.t.sol` | Tampering with every signed field, all panel constraints, malformed ABI arrays and signatures, high-s rejection, wrong consumer domain, zero IDs, freshness/expiry/deadline boundaries, stream mismatch, unsolicited failures, exact and excessive prices, insufficient funds, token/intake failures after approval/payment, duplicate outstanding IDs, reentrancy, repeated-key cooldown, immutable grid plans, and the initialized-market cap path. |
| `SwarmDeskInvariants.t.sol` | Three actors interleave donations, backup purchases, time advancement, direct/remote/permissionless answers, execution, replay, forgery, failure, expiry cleanup, and privilege attempts. Three properties run after each handler call. |

Each new fuzz property runs 1,000 cases through inline Foundry configuration. The invariant
campaign runs 256 sequences of 64 calls with unexpected reverts treated as failures. Its
explicit selector list excludes mock configuration methods and ghost-check getters.
A separate deterministic lifecycle test proves that the handler reaches successful payments,
direct and remote receipt, execution, failure, and timeout cleanup.

The invariant model tracks donations, prices paid, per-stream/slot quotas, accepted UUIDs and
delivery keys, pending request deadlines, stored answers, and execution state independently
of the corresponding Desk storage. Its guarantees are:

- Desk balance plus actual authorized spending equals all donations; the intake receives that
  spending, callers cannot recover donations, and the Desk leaves no token allowance behind.
- At most one payment and one accepted answer per stream/slot; failed/expired requests do not
  reset the paid quota; settled IDs and executed answers cannot reopen through replay.
- Registry, binding commitment, and oracle authority never change. All 45 Params remain inside
  their hard bounds; successful parameter changes obey the 10% step and daily cooldown. Event
  severity stays within 5000–7000, district hint within 0–7, and disabled event kinds stay disabled.

## Accepted issues carried forward

The requester accepts the imported-code audit's low and informational findings as known issues.
No source fix is proposed in this test submission. In particular:

- **Twin bind front-run / M-2:** the first valid factory-proven twin can win the permissionless,
  one-time bind. This is the accepted griefing/platform-trust assumption documented in
  [`docs/m2-trust-assumption.md`](../docs/m2-trust-assumption.md). Bind immediately after job A
  and check the bound registry before subsequent wiring/forwarding. The tests do not claim the
  Desk can distinguish two otherwise valid twins.
- **Finding `b2ccff161ae44616a60d99094e55b0e792c4a6baa95be8050d2ffe27f9eb3301`:** a regulator answer
  containing a cap announcement can roll back while the bound market has `initializedAt() == 0`.
  This remains an accepted issue, not asserted as desirable behavior. The approved launch order
  initializes the market in the token launch before job A, binds the Desk after job A, and only
  proposes a cap at game age >= 30 days. The added regression checks successful parameter and cap
  execution under those preconditions.
- **Reserved Params keys:** indices 3, 4, 5, 7, 8, 9, 10, 24, 25, 26, 28, 29, 30, 33, 34, 35, and 38
  have no reader, as documented in [`docs/params-keys-v313.md`](../docs/params-keys-v313.md).
  A change can consume cooldown without affecting gameplay. The committed regulator's RepairBps
  entry is unchanged; numeric bound tests do not claim every key has an economic effect.
- Immutable oracle endpoints, attester, question commitments, and maximum price carry the
  documented liveness/rotation limitations. Paid backup failures do not refund the price.
  The documented toolchain compatibility concern is addressed operationally by retaining the
  exact repo build and creation pins, not by accepting a different build.

## Scope and reproduction

Run `forge build` and `forge test` with the committed `foundry.toml`. No new dependency, FFI,
environment mutation, network access, or fork is required. Build outputs can be placed under
`test/scratch/` using `FOUNDRY_OUT=test/scratch/out` and
`FOUNDRY_CACHE_PATH=test/scratch/cache`; these only relocate disposable artifacts.

The launch rehearsal uses the exact production constructor inputs. Behavioral tests reuse the
accepted full-game fixture, its test token, explicitly test-only signing key, initialized market,
and local factory. The new intake probe pulls ERC20 payment, records requests and canonical
callbacks, applies the real 200,000-gas result stipend, and can inject external-call failures.
The Robinhood native clock is modeled locally. The existing canonical protocol digest/signature
vector tests remain intact; they provide the independent cross-implementation oracle check.

These offline tests do not verify live factory admission, the live launch registry's
`isRecorded`, production oracle delivery, or current chain state. Existing fork rehearsals remain
opt-in. A confirmed production deployment address must come from the actual deployment receipt.

## Local verification result

With the unchanged repo compiler settings (solc 0.8.26, optimizer 200, Cancun, viaIR false,
bytecode hash none), `forge build` succeeded and the full `forge test` run reported **319 passed,
0 failed, 6 skipped** across 52 suites. The six skips are the existing opt-in fork tests.
Foundry groups each invariant campaign into one reported test; all three new invariant
properties passed over 256 sequences / 16,384 handler calls with zero unexpected reverts.
The nine new stateless fuzz properties each completed 1,000 cases. The existing two JS bootstrap
tests also passed, and the constructor generator reproduced all twelve committed words.
No new critical, high, or medium SwarmDesk defect was reproduced by this work.
