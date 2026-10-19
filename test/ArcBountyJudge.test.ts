import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import {
  encodeAbiParameters,
  keccak256,
  parseAbiParameters,
  parseEther,
  toHex,
} from "viem";

// On Arc the native token is USDC with 18 decimals,
// so parseEther("10") means 10 USDC here.
const REWARD = parseEther("10");

function commitmentOf(answer: string, salt: `0x${string}`, participant: `0x${string}`, bountyId: bigint) {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("string answer, bytes32 salt, address participant, uint256 bountyId"),
      [answer, salt, participant, bountyId],
    ),
  );
}

describe("ArcBountyJudge", async () => {
  const { viem, networkHelpers } = await network.connect();
  const [owner, alice, bob] = await viem.getWalletClients();
  const publicClient = await viem.getPublicClient();

  async function setup() {
    const judge = await viem.deployContract("ArcBountyJudge");
    const now = BigInt(await networkHelpers.time.latest());
    const deadline = now + 3600n;
    const revealDeadline = deadline + 3600n;

    await judge.write.createBounty(["Best idea", "Clarity and feasibility", deadline, revealDeadline], {
      value: REWARD,
    });
    return { judge, deadline, revealDeadline, bountyId: 1n };
  }

  it("runs the full commit -> reveal -> review -> finalize -> withdraw flow", async () => {
    const { judge, deadline, revealDeadline, bountyId } = await setup();
    const salt = toHex("alice-secret-salt", { size: 32 });
    const answer = "Use USDC rewards on Arc";

    await judge.write.submitCommitment([bountyId, commitmentOf(answer, salt, alice.account.address, bountyId)], {
      account: alice.account,
    });

    await networkHelpers.time.increaseTo(deadline);
    await judge.write.revealAnswer([bountyId, answer, salt], { account: alice.account });

    await networkHelpers.time.increaseTo(revealDeadline);
    await judge.write.recordReview([bountyId, keccak256(toHex("AI review text")), "ipfs://example"]);
    await judge.write.finalizeWinner([bountyId, 0n]);

    assert.equal(await judge.read.pendingWithdrawals([alice.account.address]), REWARD);

    const before = await publicClient.getBalance({ address: alice.account.address });
    await judge.write.withdraw({ account: alice.account });
    const after = await publicClient.getBalance({ address: alice.account.address });

    assert.ok(after > before, "winner balance should increase");
    assert.equal(await judge.read.pendingWithdrawals([alice.account.address]), 0n);
  });

  it("rejects a reveal with the wrong salt", async () => {
    const { judge, deadline, bountyId } = await setup();
    const salt = toHex("right-salt", { size: 32 });
    const wrong = toHex("wrong-salt", { size: 32 });

    await judge.write.submitCommitment([bountyId, commitmentOf("answer", salt, alice.account.address, bountyId)], {
      account: alice.account,
    });
    await networkHelpers.time.increaseTo(deadline);

    await viem.assertions.revertWith(
      judge.write.revealAnswer([bountyId, "answer", wrong], { account: alice.account }),
      "invalid answer or salt",
    );
  });

  it("prevents another wallet from stealing a reveal", async () => {
    const { judge, deadline, bountyId } = await setup();
    const salt = toHex("alice-salt", { size: 32 });

    await judge.write.submitCommitment([bountyId, commitmentOf("answer", salt, alice.account.address, bountyId)], {
      account: alice.account,
    });
    await networkHelpers.time.increaseTo(deadline);

    await viem.assertions.revertWith(
      judge.write.revealAnswer([bountyId, "answer", salt], { account: bob.account }),
      "no commitment",
    );
  });

  it("refunds the owner when nobody reveals", async () => {
    const { judge, revealDeadline, bountyId } = await setup();
    await networkHelpers.time.increaseTo(revealDeadline);

    await judge.write.refundIfNoReveals([bountyId]);
    assert.equal(await judge.read.pendingWithdrawals([owner.account.address]), REWARD);
  });

  it("only lets the owner record a review", async () => {
    const { judge, deadline, revealDeadline, bountyId } = await setup();
    const salt = toHex("s", { size: 32 });
    await judge.write.submitCommitment([bountyId, commitmentOf("a", salt, alice.account.address, bountyId)], {
      account: alice.account,
    });
    await networkHelpers.time.increaseTo(deadline);
    await judge.write.revealAnswer([bountyId, "a", salt], { account: alice.account });
    await networkHelpers.time.increaseTo(revealDeadline);

    await viem.assertions.revertWith(
      judge.write.recordReview([bountyId, keccak256(toHex("x")), ""], { account: bob.account }),
      "not bounty owner",
    );
  });
});
