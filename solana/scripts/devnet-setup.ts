import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { TakumiPay } from "../target/types/takumi_pay";
import {
  Keypair,
  PublicKey,
  SystemProgram,
  Ed25519Program,
  Connection,
  clusterApiUrl,
} from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  getAssociatedTokenAddressSync,
  mintTo,
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import nacl from "tweetnacl";
import * as fs from "fs";
import * as path from "path";

const DEVNET_STATE_PATH = path.join(__dirname, "..", "deployments", "devnet-state.json");

async function sha256(data: string): Promise<number[]> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return Array.from(new Uint8Array(hash));
}

function buildQuoteMessage(params: {
  refId: string;
  merchantId: string;
  tokenMint: PublicKey;
  amount: anchor.BN;
  platformFeeAmount: anchor.BN;
  fiatAmountMinor: anchor.BN;
  fiatCurrency: number[];
  exchangeRateId: anchor.BN;
  expiresAt: anchor.BN;
}): Buffer {
  const parts: Buffer[] = [];

  const refIdBytes = Buffer.from(params.refId);
  const refIdLen = Buffer.alloc(4);
  refIdLen.writeUInt32LE(refIdBytes.length);
  parts.push(refIdLen, refIdBytes);

  const merchantIdBytes = Buffer.from(params.merchantId);
  const merchantIdLen = Buffer.alloc(4);
  merchantIdLen.writeUInt32LE(merchantIdBytes.length);
  parts.push(merchantIdLen, merchantIdBytes);

  parts.push(params.tokenMint.toBuffer());
  parts.push(params.amount.toBuffer("le", 8));
  parts.push(params.platformFeeAmount.toBuffer("le", 8));
  parts.push(params.fiatAmountMinor.toBuffer("le", 8));
  parts.push(Buffer.from(params.fiatCurrency));
  parts.push(params.exchangeRateId.toBuffer("le", 8));
  parts.push(params.expiresAt.toBuffer("le", 8));

  return Buffer.concat(parts);
}

function loadOrCreateKeypair(filePath: string): Keypair {
  if (fs.existsSync(filePath)) {
    const raw = JSON.parse(fs.readFileSync(filePath, "utf-8"));
    return Keypair.fromSecretKey(new Uint8Array(raw));
  }
  const kp = Keypair.generate();
  fs.writeFileSync(filePath, JSON.stringify(Array.from(kp.secretKey)));
  return kp;
}

function saveState(state: Record<string, any>) {
  fs.mkdirSync(path.dirname(DEVNET_STATE_PATH), { recursive: true });
  fs.writeFileSync(DEVNET_STATE_PATH, JSON.stringify(state, null, 2));
}

function loadState(): Record<string, any> | null {
  if (!fs.existsSync(DEVNET_STATE_PATH)) return null;
  return JSON.parse(fs.readFileSync(DEVNET_STATE_PATH, "utf-8"));
}

async function main() {
  const command = process.argv[2] || "setup";

  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const connection = provider.connection;
  const program = anchor.workspace.takumiPay as Program<TakumiPay>;
  const owner = provider.wallet as anchor.Wallet;

  const [configPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("config")],
    program.programId
  );

  const backendSignerPath = path.join(__dirname, "..", "deployments", "backend-signer-devnet.json");

  if (command === "setup") {
    await setup(program, connection, owner, configPda, backendSignerPath);
  } else if (command === "test-merchant") {
    await testMerchantPayment(program, connection, owner, configPda, backendSignerPath);
  } else {
    console.log("Usage: ts-mocha scripts/devnet-setup.ts [setup|test-merchant]");
    console.log("\nOr run directly with:");
    console.log("  npx ts-node scripts/devnet-setup.ts setup");
    console.log("  npx ts-node scripts/devnet-setup.ts test-merchant");
  }
}

async function setup(
  program: Program<TakumiPay>,
  connection: Connection,
  owner: anchor.Wallet,
  configPda: PublicKey,
  backendSignerPath: string
) {
  console.log("=== TakumiPay Devnet Setup ===\n");
  console.log("Program ID:", program.programId.toBase58());
  console.log("Owner:", owner.publicKey.toBase58());
  console.log("Config PDA:", configPda.toBase58());

  // Step 1: Initialize contract (skip if already done)
  const backendSigner = loadOrCreateKeypair(backendSignerPath);
  console.log("\nBackend Signer:", backendSigner.publicKey.toBase58());
  console.log("Backend Signer keypair saved to:", backendSignerPath);

  let configAccount = await connection.getAccountInfo(configPda);
  if (configAccount) {
    console.log("\n✓ Contract already initialized, skipping...");
    const config = await program.account.config.fetch(configPda);
    console.log("  Owner:", config.owner.toBase58());
    console.log("  Backend Signer:", config.backendSigner.toBase58());
    console.log("  Tx Counter:", config.txCounter.toNumber());

    if (config.backendSigner.toBase58() !== backendSigner.publicKey.toBase58()) {
      console.log("\n⚠ Backend signer mismatch! Rotating to match local keypair...");
      await program.methods
        .rotateBackendSigner(backendSigner.publicKey)
        .accounts({ owner: owner.publicKey } as any)
        .rpc();
      console.log("✓ Backend signer rotated");
    }
  } else {
    console.log("\nInitializing contract...");
    const tx = await program.methods
      .initialize(backendSigner.publicKey)
      .accounts({
        owner: owner.publicKey,
      } as any)
      .rpc();
    console.log("✓ Contract initialized. Tx:", tx);
  }

  // Step 2: Create mock USDC mint
  const existingState = loadState();
  let mockUsdcMint: PublicKey;

  if (existingState?.mockUsdcMint) {
    mockUsdcMint = new PublicKey(existingState.mockUsdcMint);
    const mintInfo = await connection.getAccountInfo(mockUsdcMint);
    if (mintInfo) {
      console.log("\n✓ Mock USDC mint already exists:", mockUsdcMint.toBase58());
    } else {
      console.log("\nPrevious mock USDC not found, creating new one...");
      mockUsdcMint = await createNewMockUsdc(connection, owner);
    }
  } else {
    mockUsdcMint = await createNewMockUsdc(connection, owner);
  }

  // Step 3: Mint test USDC to owner
  const ownerAta = await getOrCreateAssociatedTokenAccount(
    connection,
    owner.payer,
    mockUsdcMint,
    owner.publicKey
  );

  const currentBalance = Number(ownerAta.amount);
  const TARGET_BALANCE = 10_000_000_000; // 10,000 USDC (6 decimals)

  if (currentBalance < TARGET_BALANCE) {
    const mintAmount = TARGET_BALANCE - currentBalance;
    console.log(`\nMinting ${mintAmount / 1_000_000} mock USDC to owner...`);
    await mintTo(
      connection,
      owner.payer,
      mockUsdcMint,
      ownerAta.address,
      owner.publicKey,
      mintAmount
    );
    console.log("✓ Minted. Balance:", TARGET_BALANCE / 1_000_000, "USDC");
  } else {
    console.log("\n✓ Owner already has", currentBalance / 1_000_000, "mock USDC");
  }

  // Step 4: Allowlist the mint for payments. Every value-in entrypoint
  // (create_transaction_*, process_merchant_payment_*, deposit_points) is gated
  // on this PDA existing, so without it the contract accepts nothing.
  const [allowedTokenPda] = PublicKey.findProgramAddressSync(
    [
      Buffer.from("allowed_payment_token"),
      configPda.toBuffer(),
      mockUsdcMint.toBuffer(),
    ],
    program.programId
  );

  const allowedInfo = await connection.getAccountInfo(allowedTokenPda);
  if (allowedInfo) {
    console.log("\n✓ Mock USDC already allowlisted for payments");
  } else {
    console.log("\nAllowlisting mock USDC for payments...");
    await program.methods
      .addAllowedPaymentToken(mockUsdcMint)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        allowedToken: allowedTokenPda,
        systemProgram: SystemProgram.programId,
      } as any)
      .rpc();
    console.log("✓ Allowlisted:", allowedTokenPda.toBase58());
  }

  // Save state
  const state = {
    programId: program.programId.toBase58(),
    configPda: configPda.toBase58(),
    owner: owner.publicKey.toBase58(),
    backendSigner: backendSigner.publicKey.toBase58(),
    mockUsdcMint: mockUsdcMint.toBase58(),
    ownerUsdcAta: ownerAta.address.toBase58(),
    cluster: "devnet",
    setupAt: new Date().toISOString(),
  };
  saveState(state);

  console.log("\n=== Setup Complete ===");
  console.log("\nState saved to:", DEVNET_STATE_PATH);
  console.log("\nNext: run 'test-merchant' to test a merchant payment:");
  console.log("  npx ts-node scripts/devnet-setup.ts test-merchant");
}

async function createNewMockUsdc(connection: Connection, owner: anchor.Wallet): Promise<PublicKey> {
  console.log("\nCreating mock USDC mint (6 decimals)...");
  const mint = await createMint(connection, owner.payer, owner.publicKey, null, 6);
  console.log("✓ Mock USDC mint created:", mint.toBase58());
  return mint;
}

async function testMerchantPayment(
  program: Program<TakumiPay>,
  connection: Connection,
  owner: anchor.Wallet,
  configPda: PublicKey,
  backendSignerPath: string
) {
  console.log("=== Test Merchant Payment (Token) ===\n");

  const state = loadState();
  if (!state) {
    console.error("No devnet state found. Run 'setup' first.");
    process.exit(1);
  }

  const backendSigner = loadOrCreateKeypair(backendSignerPath);
  const mockUsdcMint = new PublicKey(state.mockUsdcMint);

  console.log("Program ID:", state.programId);
  console.log("Mock USDC:", mockUsdcMint.toBase58());
  console.log("Backend Signer:", backendSigner.publicKey.toBase58());

  // Build merchant payment params
  const refId = `merchant-devnet-${Date.now()}`;
  const refIdHash = await sha256(refId);
  const expiresAt = new anchor.BN(Math.floor(Date.now() / 1000) + 300);

  const quoteParams = {
    refId,
    merchantId: "merchant-test-001",
    tokenMint: mockUsdcMint,
    amount: new anchor.BN(5_000_000),         // 5 USDC
    platformFeeAmount: new anchor.BN(250_000), // 0.25 USDC (5% fee)
    fiatAmountMinor: new anchor.BN(500),       // $5.00
    fiatCurrency: [85, 83, 68],                // "USD"
    exchangeRateId: new anchor.BN(1),
    expiresAt,
  };

  console.log("\nQuote params:");
  console.log("  Ref ID:", refId);
  console.log("  Merchant:", quoteParams.merchantId);
  console.log("  Amount:", quoteParams.amount.toNumber() / 1_000_000, "USDC");
  console.log("  Platform fee:", quoteParams.platformFeeAmount.toNumber() / 1_000_000, "USDC");
  console.log("  Fiat:", quoteParams.fiatAmountMinor.toNumber() / 100, "USD");

  // Sign the quote with backend signer
  const message = buildQuoteMessage(quoteParams);
  const signature = nacl.sign.detached(message, backendSigner.secretKey);

  const ed25519Ix = Ed25519Program.createInstructionWithPublicKey({
    publicKey: backendSigner.publicKey.toBytes(),
    message,
    signature,
  });

  // Derive PDAs
  const [merchantPaymentPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("merchant_payment"), configPda.toBuffer(), Buffer.from(refIdHash)],
    program.programId
  );
  const [platformFeePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("platform_fee"), configPda.toBuffer(), mockUsdcMint.toBuffer()],
    program.programId
  );
  const [allowedTokenPda] = PublicKey.findProgramAddressSync(
    [
      Buffer.from("allowed_payment_token"),
      configPda.toBuffer(),
      mockUsdcMint.toBuffer(),
    ],
    program.programId
  );

  const payerAta = getAssociatedTokenAddressSync(mockUsdcMint, owner.publicKey);
  const vaultAta = getAssociatedTokenAddressSync(mockUsdcMint, configPda, true);

  console.log("\nSending merchant payment transaction...");

  try {
    const tx = await program.methods
      .processMerchantPaymentToken({
        refId,
        refIdHash,
        merchantId: quoteParams.merchantId,
        amount: quoteParams.amount,
        platformFeeAmount: quoteParams.platformFeeAmount,
        fiatAmountMinor: quoteParams.fiatAmountMinor,
        fiatCurrency: quoteParams.fiatCurrency,
        exchangeRateId: quoteParams.exchangeRateId,
        expiresAt,
      })
      .accounts({
        payer: owner.publicKey,
        merchantPayment: merchantPaymentPda,
        platformFeeAccount: platformFeePda,
        tokenMint: mockUsdcMint,
        allowedToken: allowedTokenPda,
        payerTokenAccount: payerAta,
        vaultTokenAccount: vaultAta,
        instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      } as any)
      .preInstructions([ed25519Ix])
      .rpc();

    console.log("\n✓ Merchant payment successful!");
    console.log("  Tx:", tx);
    console.log("  Explorer: https://explorer.solana.com/tx/" + tx + "?cluster=devnet");

    // Verify on-chain state
    const mp = await program.account.merchantPayment.fetch(merchantPaymentPda);
    console.log("\nOn-chain merchant payment record:");
    console.log("  Ref ID:", mp.refId);
    console.log("  Merchant:", mp.merchantId);
    console.log("  Amount:", mp.amount.toNumber() / 1_000_000, "USDC");
    console.log("  Platform fee:", mp.platformFeeAmount.toNumber() / 1_000_000, "USDC");
    console.log("  Fiat:", mp.fiatAmountMinor.toNumber() / 100, "USD");
    console.log("  Payer:", mp.payer.toBase58());
    console.log("  Token mint:", mp.tokenMint.toBase58());
  } catch (err: any) {
    console.error("\n✗ Merchant payment failed:");
    console.error(err.message || err);
    if (err.logs) {
      console.error("\nProgram logs:");
      err.logs.forEach((log: string) => console.error("  ", log));
    }
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
