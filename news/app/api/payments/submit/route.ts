import { NextResponse } from "next/server";
import crypto from "crypto";
import bs58 from "bs58";
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";

import { getJson, setJson } from "@/lib/storage/settlementStore";

type CanonicalStatus =
  | "settled"
  | "submitted"
  | "duplicate"
  | "conflict"
  | "failed"
  | "expired"
  | "invalid";

type SubmitResponse = {
  payment_id: string;
  canonical_status: CanonicalStatus;
  backend_receipt_id?: string;
  transaction_signature?: string;
  settled_at?: number | null;
  failure_reason?: string | null;
  conflict_reason?: string | null;
  canonical_sequence?: number | null;
};

type SubmitRequest = {
  payment_id: string;
  sender_device_id: string;
  recipient_device_id?: string;
  amount_minor: number;
  asset_code: string;
  memo?: string;
  created_at: number;
  expires_at?: number | null;
  local_sequence: number;
  sender_signature: string;
  raw_payload_json: string;

  sender_wallet_address?: string | null;
  recipient_wallet_address?: string | null;

  submitted_by_device_id: string;
  app_version?: string;
  schema_version?: number;
};

function sha256Hex(input: string): string {
  return crypto.createHash("sha256").update(input, "utf8").digest("hex");
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function getSolanaDevnetRpcUrl(): string {
  if (process.env.SOLANA_DEVNET_RPC_URL?.trim()) return process.env.SOLANA_DEVNET_RPC_URL.trim();
  const key = process.env.HELIUS_DEVNET_API_KEY?.trim();
  if (!key) {
    throw new Error("Missing SOLANA_DEVNET_RPC_URL or HELIUS_DEVNET_API_KEY");
  }
  return `https://devnet.helius-rpc.com/?api-key=${key}`;
}

async function getBackendPayer(): Promise<Keypair> {
  // Primary env var used for the payer signing key.
  // Fallback to `PRIVATE_KEY` since the repo's News/.env currently uses that name.
  const b58 =
    process.env.SOLANA_BACKEND_PAYER_SECRET_KEY_B58?.trim() ||
    process.env.PRIVATE_KEY?.trim();
  if (!b58) throw new Error("Missing SOLANA_BACKEND_PAYER_SECRET_KEY_B58 (or PRIVATE_KEY)");
  const secret = bs58.decode(b58);
  return Keypair.fromSecretKey(secret);
}

function makeRedisKey(prefix: string, payment_id: string, sender_device_id: string, local_sequence?: number): string {
  if (local_sequence == null) return `${prefix}:${payment_id}:${sender_device_id}`;
  return `${prefix}:${payment_id}:${sender_device_id}:${local_sequence}`;
}

export async function POST(req: Request) {
  try {
    const body = (await req.json()) as SubmitRequest;

    // Minimal validation: reject malformed payments early.
    if (!body.payment_id?.trim() || !body.sender_device_id?.trim()) {
      return NextResponse.json(
        { payment_id: body.payment_id ?? "", canonical_status: "invalid", failure_reason: "Missing payment_id/sender_device_id" },
        { status: 400 }
      );
    }
    if (!body.asset_code?.trim()) {
      return NextResponse.json(
        { payment_id: body.payment_id, canonical_status: "invalid", failure_reason: "Missing asset_code" },
        { status: 400 }
      );
    }
    if (!Number.isFinite(body.amount_minor) || body.amount_minor <= 0) {
      return NextResponse.json(
        { payment_id: body.payment_id, canonical_status: "invalid", failure_reason: "amount_minor must be > 0" },
        { status: 400 }
      );
    }

    const createdAt = body.created_at ?? nowSeconds();
    const expiresAt = body.expires_at ?? null;
    const localSeq = Number(body.local_sequence ?? 0);

    if (expiresAt != null && Number(expiresAt) <= nowSeconds()) {
      return NextResponse.json({
        payment_id: body.payment_id,
        canonical_status: "expired",
        backend_receipt_id: `exp-${body.payment_id}`,
        settled_at: null,
        failure_reason: "Payment expired",
        conflict_reason: null,
        canonical_sequence: null,
      } satisfies SubmitResponse);
    }

    // Canonical hash of what the sender signed. Used for conflict detection.
    const payloadHash = sha256Hex(body.raw_payload_json + "|" + body.sender_signature);

    const dedupKey = makeRedisKey("settle:dedup", body.payment_id, body.sender_device_id, localSeq);
    const claimKey = makeRedisKey("settle:claim", body.payment_id, body.sender_device_id);

    // Idempotency: exact duplicate submission.
    const priorDedup = await getJson<SubmitResponse>(dedupKey);
    if (priorDedup) {
      // Keep the original receipt metadata, but signal that this request is a duplicate.
      const dup: SubmitResponse = {
        ...priorDedup,
        canonical_status: "duplicate",
        // Preserve settled_at / tx signature / reasons from the original outcome.
      };
      return NextResponse.json(dup);
    }

    // Conflict: same payment_id+sender but different local_sequence or payload.
    const priorClaim = await getJson<{ local_sequence: number; payload_hash: string }>(claimKey);
    if (priorClaim) {
      const seqMismatch = priorClaim.local_sequence !== localSeq;
      const hashMismatch = priorClaim.payload_hash !== payloadHash;
      if (seqMismatch || hashMismatch) {
        const resp: SubmitResponse = {
          payment_id: body.payment_id,
          canonical_status: "conflict",
          backend_receipt_id: `conf-${body.payment_id}`,
          transaction_signature: undefined,
          settled_at: null,
          failure_reason: null,
          conflict_reason: seqMismatch
            ? "local_sequence mismatch for same payment_id/sender_device_id"
            : "payload hash mismatch for same payment_id/sender_device_id",
          canonical_sequence: null,
        };
        // Persist so we don't thrash on repeated submissions.
        await setJson(dedupKey, resp);
        return NextResponse.json(resp);
      }
    } else {
      await setJson(claimKey, { local_sequence: localSeq, payload_hash: payloadHash });
    }

    // Submit: for Wave 2 we only settle native SOL (asset_code == "SOL").
    // TODO: SPL tokens support + richer asset mapping.
    if (body.asset_code !== "SOL") {
      const resp: SubmitResponse = {
        payment_id: body.payment_id,
        canonical_status: "invalid",
        backend_receipt_id: `inv-${body.payment_id}`,
        settled_at: null,
        failure_reason: `Unsupported asset_code: ${body.asset_code}`,
        conflict_reason: null,
        canonical_sequence: null,
      };
      await setJson(dedupKey, resp);
      return NextResponse.json(resp, { status: 400 });
    }

    const recipientAddr = (body.recipient_wallet_address ?? "").trim();
    if (!recipientAddr) {
      const resp: SubmitResponse = {
        payment_id: body.payment_id,
        canonical_status: "failed",
        backend_receipt_id: `fail-${body.payment_id}`,
        settled_at: null,
        failure_reason: "Missing recipient_wallet_address",
        conflict_reason: null,
        canonical_sequence: null,
      };
      await setJson(dedupKey, resp);
      return NextResponse.json(resp, { status: 200 });
    }

    let txSignature: string | null = null;

    const connection = new Connection(getSolanaDevnetRpcUrl(), "confirmed");
    const payer = await getBackendPayer();

    const to = new PublicKey(recipientAddr);
    const lamports = Number(body.amount_minor);
    if (!Number.isFinite(lamports) || lamports <= 0) throw new Error("amount_minor must be > 0");
    if (lamports > Number.MAX_SAFE_INTEGER) {
      throw new Error("amount_minor too large for JS number (expected devnet MVP range)");
    }

    const tx = new Transaction();
    tx.add(
      SystemProgram.transfer({
        fromPubkey: payer.publicKey,
        toPubkey: to,
        lamports,
      })
    );

    tx.feePayer = payer.publicKey;

    // Latest blockhash + explicit signing.
    const { blockhash } = await connection.getLatestBlockhash("confirmed");
    tx.recentBlockhash = blockhash;
    const sig = await sendAndConfirmTransaction(connection, tx, [payer]);
    txSignature = sig;

    const resp: SubmitResponse = {
      payment_id: body.payment_id,
      canonical_status: "settled",
      backend_receipt_id: `rcpt-${body.payment_id}`,
      transaction_signature: txSignature ?? undefined,
      settled_at: nowSeconds(),
      failure_reason: null,
      conflict_reason: null,
      canonical_sequence: Date.now(),
    };

    await setJson(dedupKey, resp);
    return NextResponse.json(resp);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("[payments/submit] error:", msg);
    // Transient / backend errors should be treated as retryable by the client.
    return NextResponse.json(
      { payment_id: "unknown", canonical_status: "failed", failure_reason: msg },
      { status: 500 }
    );
  }
}

