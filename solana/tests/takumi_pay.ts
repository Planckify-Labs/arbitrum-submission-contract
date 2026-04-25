import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { TakumiPay } from "../target/types/takumi_pay";

describe("takumi_pay", () => {
  anchor.setProvider(anchor.AnchorProvider.env());

  const program = anchor.workspace.takumiPay as Program<TakumiPay>;

  it("Is initialized!", async () => {
    const tx = await program.methods.initialize().rpc();
    console.log("Your transaction signature", tx);
  });
});
