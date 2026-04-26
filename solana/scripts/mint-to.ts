import { Connection, PublicKey, Keypair } from "@solana/web3.js";
import {
  createAssociatedTokenAccountIdempotent,
  mintTo,
  getAccount,
} from "@solana/spl-token";
import * as fs from "fs";

async function main() {
  const conn = new Connection("https://api.devnet.solana.com", "confirmed");
  const walletKey = JSON.parse(
    fs.readFileSync("/Users/satriaali/.config/solana/id.json", "utf-8"),
  );
  const payer = Keypair.fromSecretKey(new Uint8Array(walletKey));

  const mint = new PublicKey("4qFejVSp46Q4SZCGDrXbkFJC1qw5uo1JBnbXLnKZurey");
  const recipient = new PublicKey(
    "4JmhaLQgFZMckU9ss6inWvHvoBkTVXV4e114L3PKxbiL",
  );

  console.log("Creating ATA for recipient...");
  const ata = await createAssociatedTokenAccountIdempotent(
    conn,
    payer,
    mint,
    recipient,
  );
  console.log("ATA:", ata.toBase58());

  // 4 billion USDC with 6 decimals
  const amount = 4_000_000_000_000_000;
  console.log("Minting 4,000,000,000 USDC...");

  const sig = await mintTo(conn, payer, mint, ata, payer, amount);
  console.log("Mint tx:", sig);

  const account = await getAccount(conn, ata);
  console.log(
    "Balance:",
    (Number(account.amount) / 1_000_000).toLocaleString(),
    "USDC",
  );
}

main().catch(console.error);
