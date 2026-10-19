import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("ArcBountyJudgeModule", (m) => {
  const judge = m.contract("ArcBountyJudge");
  return { judge };
});
