# BLACKOUT SwarmDesk bootstrap — Robinhood Chain 4663

Prepared from `identity-md-launches/launch-1544-blackout-swarmdesk-bootstrap-robinhood`, commit
`24bfb1d700159042da4b08262927727d37170540` (BLACKOUT v3.13). The bootstrap launch deploys exactly
one application, `src/SwarmDesk.sol:SwarmDesk`, unbound and with zero deployment value.

## Changes and reasons

| File | Change | Requirement |
| --- | --- | --- |
| `docs/swarm-bootstrap-v313/binding.json` | Records the supplied ProjectFactory, zero bind-time coordinates, 200 bps heartbeat, 1e18 cap and exact GAME_CONFIG_HASH. | Gives the existing constructor tool complete, approved inputs without guessing roots, launch numbers or ownership. |
| `docs/swarm-bootstrap-v313/constructor-args.json` | Records the existing tool's output: the twelve approved static words in order. | Provides reproducible constructor input for the subsequent manifest/deployment step. |
| `test/SwarmDeskBootstrap.t.sol` | Adds four offline tests using the actual SwarmDesk artifact and approved constructor words. | Checks the creation hash, factory deployment, one creation, no external constructor calls, unbound state, complete config, runtime policy and the deployed Desk's chain-4663 EIP-712 domain. |
| `test/swarm-bootstrap.test.mjs` | Checks the committed inputs and regenerated words against the assignment's exact values and independently decodes the packed policy. | Guards the documented launch inputs against drift; uses only Node built-ins and the existing tool. |
| `ADAPTATION.md` | Records this handoff, verification and the accepted audit findings. | Required launch notes and change rationale. |

No existing Solidity source, deployment script, oracle body, commitment, pin, build configuration or
dependency was changed. The requested constructor already meets the launch requirements: twelve static
nonpayable arguments, no owner/admin, no external constructor call and no post-deployment initialization
needed for bootstrap. Existing behavior, including all accepted low/info findings, is preserved.
`test/scratch/ImportedAuditProbe.t.sol` was used only for local reproductions and is excluded from submission.

## Exact build and constructor input

Use the repository's unchanged `foundry.toml`: Solidity 0.8.26, optimizer enabled with 200 runs,
Cancun, `via_ir = false`, `bytecode_hash = "none"`. Deploy `out/SwarmDesk.sol/SwarmDesk.json`
creation code exactly as built, with the twelve words from `constructor-args.json`. Do not deploy the
test factory, another application, a token, an escrow or a hook in this bootstrap.

Verified creation-code keccak256:
`0x65968358bcf87aa8839b8bce6b2d339493deac3f77d75a3ff0b3ad4f35955745`.
Creation code is 23,338 bytes; with the 384-byte constructor payload, init code is 23,722 bytes.
The complete init-code keccak256 (creation code plus these constructor words) is
`0xe598a845ff315b0d91df76c14d2c3c79461360c4257840333c0bcb611b7d3d37`.
Deployed runtime is 20,797 bytes, below the 24,576-byte EIP-170 limit. The local runtime scan passes
the protected floor's PUSH-aware exclusion of DELEGATECALL, CALLCODE and SELFDESTRUCT.

Regenerate the documented words offline:

```sh
node tools/swarm_constructor_args.mjs docs/oracle-v37/oracle-config.json docs/swarm-bootstrap-v313/binding.json
node --test test/swarm-bootstrap.test.mjs
```

Constructor ABI, in order:
`address,address,address,address,bytes32,uint256,bytes32,bytes32,bytes32,bytes32,address,bytes32`.
The sixth word is
`5391989333430298100116863486635657822062725418115979424500284366258177`.
It decodes to question chain 1, blocks 26,122,900–26,122,901, maximum price 500,000,000,000,000,000
and heartbeat 200 bps; bits 240–255 are zero. Question chain 1 is the oracle's evidence context;
the consumer's EIP-712 domain is Robinhood Chain 4663 and the deployed SwarmDesk address.
The last word is GAME_CONFIG_HASH:
`0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3`.

## Deployment handoff and checks

This contribution prepares the application for the IMD manifest, verifier and deployment service.
No worker broadcast was performed. The confirmed production address and transaction receipt must be
recorded and returned by that service after deployment; no production address is claimed by the local
rehearsal. Its fixture coordinates `(1,0)` are local test data, never a reservation or manifest input.
The manifest belongs to the subsequent step and is not created here.

ProjectFactory: `0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e` (`predictContract`).
Platform launch registry: `0xf52bbe066b7ad2d28c2195d066ea08dcbca88406` (`isRecorded`).
The launch registry is a platform proof endpoint, not an additional constructor word or bootstrap
deployment target. The Desk's own `registry()` is the game registry and must initially be zero.

After the service supplies the real Desk address and recorded launch coordinates, verify the recorded
contract against the factory prediction and check these read results on chain 4663:

| Read | Required result |
| --- | --- |
| `registry()` | `0x0000000000000000000000000000000000000000` (deliberately unbound) |
| `bindingConfig().factory` | `0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e` |
| `bindingConfig().gameConfigHash` | `0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3` |
| `bindingConfig().registryLaunch / registryIndex / paramsLaunch / paramsIndex` | All zero until binding |
| `bindingConfig().heartbeatBps / heartbeatCap` | `200 / 1000000000000000000` |
| `oracleConfig()` | Matches `docs/oracle-v37/oracle-config.json` |
| `oracleSigner()` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |

The binding getter's ABI result is
`(address,uint64,uint8,uint64,uint8,bytes32,uint256,uint256)` in that order. Bind only after job A,
which follows the token launch that initializes the market. Binding is permissionless and one-time,
proving pinned Registry/Params creation code and configuration through the ProjectFactory. The keeper
must bind immediately after job A and verify that `registry()` is the honest job A registry before
later wiring or endowment forwarding. Those later jobs/actions are outside this bootstrap.

## Imported audit: reproduced and accepted without source changes

The assignment expressly accepts all low/info findings and pins the creation code. The following
reproductions are observations of the imported code, not fixes or independent security approval.

1. **Low — malformed regulator codes are clamped rather than skipped.**
   ID `1c443300d9cf4876e25b634b69ec5498b3f1e6ce73e0a8bd1d0c79a508f64083`.
   Reproduced: signed key byte 255 with target 7e18 changes RepairHours from 6e18 to 6.6e18 and
   consumes its cooldown. Feature code 1000 announces feature 7 for now + 48 hours. Hard parameter
   bounds, the 10% step and feature notice delay still apply. Scratch tests
   `testUnknownKeyClampsToRepairHoursAndBurnsCooldown` and `testUnknownFeatureClampsToFeatureSeven`
   passed. Retained as requested; skipping invalid codes would change the pinned creation code.

2. **Info — any relayer may submit a signed pinned-question answer from the minimum 5/4 panel.**
   ID `5023720b959e359989175b6d3a5232361ebb87ab6710535f213582938a8c3883`.
   Reproduced: an unrelated relayer's answer with panelSize 5, quorum 4 and agreed 4 is stored;
   a later 30/20/30 answer for the same slot is ignored with reason 2. Scratch test
   `testMinimumPanelRelayWinsSlotOverLaterLargerPanel` passed. Existing
   `SwarmDeskV37Test.testSubmitRelayAcceptsAttestedAnswerFromAnyoneOnce` also passes.
   This is the accepted IMD panel/single-attester trust model; a relayer cannot forge authority.

3. **Info — protocol configuration has no rotation/recovery setter.**
   ID `ec0a447e962a47dc76cc12660b6b59c19d30f6eab2d5e74f39d499c45ab630b4`.
   Reproduced: a backup price of 500000000000000001 reverts `InvalidValue`; an attestation from
   another key reverts `BadSignature`, and the signer setter is absent. Scratch tests
   `testPriceOneWeiAboveImmutableCapRejectsBackup` and `testRotatedSignerHasNoRecoveryAuthority`
   passed. Existing `testBackupFailureUnknownFailureDeadlineAndPriceCap` also passes.
   The explicit no-owner/no-admin brief takes precedence over the generic owner-settable oracle
   reference. A protocol rotation can strand backup/attested operation; existing fallback plans
   and frozen Params remain the game's accepted behavior.

4. **Info — stale severity NatSpec.**
   ID `01ce7cc9c40f3ef6ff6d717f4a0c9221c57ad5da929845c26201289390d4d63d`.
   Reproduced: an authorized GridOperator outage plan accepts severity 3000, while the Desk still
   clamps its own answers to 5000–7000. Scratch test
   `testGridAcceptsSeverityThreeThousandDespiteDeskComment` passed. The comment in SwarmDesk still
   says 5000–10000; this discrepancy is recorded here and existing review item I-2 remains accepted.

No listed imported finding failed to reproduce. None requires a source change under this launch's
explicit acceptance; no new critical, high or medium SwarmDesk defect was reproduced in these checks.

Additional accepted launch-order issue:
`b2ccff161ae44616a60d99094e55b0e792c4a6baa95be8050d2ffe27f9eb3301`.
Scratch test `testCapRollbackNeedsUninitializedMarketAndInitializedMarketExecutes` reproduces an
execution rollback when the bound market is forced to report `initializedAt() == 0`: the earlier
Params write and cap announcement roll back, and the answer remains pending. Restoring the initialized
market permits the same answer to execute. The required order initializes the market in the token
launch before job A and Desk binding, and a cap proposal is made only at game age >= 30 days. The
uninitialized condition is therefore unreachable in this launch order; no source fix is made.

The twin-bind race in `docs/m2-trust-assumption.md` remains accepted: a byte-identical paid/admitted
factory launch can bind first and orphan the honest game (griefing). It does not grant an attacker
owner, withdrawal or arbitrary asset authority. Immediate honest binding after job A is the mitigation.

The seventeen reader-less Params keys remain reserved as documented in `docs/params-keys-v313.md`:
indices 3, 4, 5, 7, 8, 9, 10, 24, 25, 26, 28, 29, 30, 33, 34, 35 and 38. A change to one can write
storage and consume its cooldown without affecting game behavior. The committed regulator includes
RepairBps (index 8) at its default, so that proposal is skipped; its oracle body and question commitments
remain unchanged. HeartbeatBps (index 40) has its v3.13 FeeRouter reader and is not reserved.

## Local verification

The final `forge build` passed with the repository configuration. Final `forge test` passed across
50 suites: **284 passed, 0 failed, 6 skipped**, including the four new bootstrap tests and seven
temporary scratch reproduction tests. The unchanged original suite had 273 passing tests and the
same six skips. The two new Node tests passed. Existing protocol-vector tests, oracle commitment/packing
checks (`node test/oracle-v37.test.mjs`, `node test/oracle-v310.test.mjs`) and the authority check
(`python3 tools/check_v37_authority.py`) also passed.

For the existing pin tools, `forge build --out out-launch` generated the second artifact directory
with the same repository configuration. `python3 tools/pin_module_code.py --check` and
`python3 tools/pin_swarm_code.py --check` passed, with all fourteen module pins, Registry/Params pins
and runtime sizes intact. The SwarmDesk creation hash independently matches the required value in
both `out` and `out-launch`; there are no bytecode link references. The source/config/dependency diff
is empty. No new dependency is needed for offline verification.

The supplied `Contracts.protected.t.sol` was also rehearsed unchanged from a temporary scratch copy,
using chain 4663, the supplied factory and the exact built creation code plus constructor words.
Its constructor/prediction and runtime policy check passed (1 test); the temporary copy was removed
after the run. All factory coordinates and addresses used in this rehearsal were local fixture results.

Slither and Mythril were not run. Existing optional fork tests are skipped in the offline suite;
these local results do not claim live platform deployment or RPC verification.

Project: https://playblackout.xyz · https://x.com/IMDBlackout
