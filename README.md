# Arc Bounty Judge

A commit-reveal bounty contract with off-chain AI review, deployed on **Arc Testnet** and paying rewards in **native USDC**.

This project started from a Ritual Chain workshop (an on-chain AI bounty judge). I extended it with a commit-reveal submission flow, then ported it to Arc and redesigned the parts that depend on Arc's stablecoin-native execution model.

## Deployment

| Network | Chain ID | Contract |
| :- | :- | :- |
| Arc Testnet | 5042002 | [`0x126543bc51092756F61d4E347B6EF969c817599e`](https://explorer.testnet.arc.io/address/0x126543bc51092756F61d4E347B6EF969c817599e) |

## What changed for Arc

**1. Rewards are native USDC.**
Arc's native gas token is USDC, so `msg.value` in `createBounty` is already USDC. The reward flow needs no ERC-20 approval or wrapper. All amounts in the contract are native values with **18 decimals**. They are never mixed with the ERC-20 USDC interface (6 decimals), since the two views of the same balance differ by 10^12.

**2. Pull payments instead of direct transfers.**
On Arc, a native value transfer can revert even with sufficient balance (for example, when an address is blocklisted). Instead of sending the reward inside `finalizeWinner`, the contract credits `pendingWithdrawals` and the winner calls `withdraw()`. State is cleared before the external call.

**3. Off-chain AI review, on-chain commitment.**
The original version called Ritual's LLM inference precompile, which does not exist on Arc. Here the bounty owner runs the AI review off-chain and records `keccak256(review)` plus a URI with `recordReview`. Anyone can fetch the review and check it against the stored hash.

**4. Refund path.**
If nobody reveals a valid answer before the reveal deadline, the owner can reclaim the reward with `refundIfNoReveals`.

## Bounty lifecycle

1. **Create**: `createBounty(title, rubric, deadline, revealDeadline)` with the USDC reward as `msg.value`.
2. **Commit**: before the deadline, each participant submits `keccak256(abi.encode(answer, salt, participant, bountyId))` with `submitCommitment`.
3. **Reveal**: between the deadline and the reveal deadline, the same wallet calls `revealAnswer(bountyId, answer, salt)`. The contract recomputes the commitment, so a changed answer, a wrong salt or a different wallet fails.
4. **Review**: after the reveal deadline, the owner records the off-chain AI review hash with `recordReview`.
5. **Finalize**: the owner picks a revealed submission with `finalizeWinner`, which credits the reward.
6. **Withdraw**: the winner calls `withdraw()`.

Binding the commitment to the participant address prevents another wallet from stealing a reveal, and binding it to the bounty ID prevents reuse across bounties.

## Computing a commitment (viem)

```ts
import { encodeAbiParameters, keccak256, parseAbiParameters } from "viem";

const commitment = keccak256(
  encodeAbiParameters(
    parseAbiParameters("string answer, bytes32 salt, address participant, uint256 bountyId"),
    [answer, salt, participantAddress, bountyId],
  ),
);
```

Use `encodeAbiParameters`, which matches Solidity's `abi.encode`. Do not use `encodePacked`.

## Run locally

Requirements: Node.js 22+, pnpm

```bash
pnpm install
npx hardhat compile
npx hardhat test nodejs
```

Tests cover the full commit → reveal → review → finalize → withdraw flow, a wrong-salt reveal, a reveal attempt from another wallet, the no-reveal refund, and owner-only review recording.

## Deploy to Arc Testnet

1. Get testnet USDC from the [Circle faucet](https://faucet.circle.com).
2. Store the deployer key in the Hardhat keystore (never in code):
   ```bash
   npx hardhat keystore set ARC_DEPLOYER_PRIVATE_KEY
   ```
3. Deploy:
   ```bash
   npx hardhat ignition deploy ignition/modules/ArcBountyJudge.module.ts --network arcTestnet
   ```

## Notes

- `block.timestamp` on Arc is non-decreasing rather than strictly increasing, which is fine for the deadline checks used here.
- AI output is a recommendation. The final winner selection is an on-chain action attributable to the bounty owner.
- This is a testnet project and has not been audited.

## References

- [Arc docs](https://docs.arc.io)
- [Arc EVM differences](https://docs.arc.io/arc/references/evm-differences)
- [Connect to Arc](https://docs.arc.io/arc/references/connect-to-arc)
