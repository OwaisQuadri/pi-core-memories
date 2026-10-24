import { createHash } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const inputLimit = 4_194_304;
const outputLimit = 8_388_608;
export const SOURCE_PROTECTION_REPLY_BYTES = outputLimit * 6 + 65_536;
export const SOURCE_PROTECTION_INPUT_BYTES = inputLimit * 6 + 65_536;
const codes = ["not-ready", "unavailable", "timeout", "cancelled", "invalid-input", "invalid-output", "failed"] as const;
type BlockedCode = typeof codes[number];
type Binding = { version: 1; type: "sourceProtectionResult"; invocationID: string; requestID: string; inputDigest: string };
export type SourceProtectionResult = Binding & (
	| { status: "blocked"; code: BlockedCode }
	| { status: "checked"; policy: "pi-credentials/redact-v1"; pieces: string[]; outputDigest: string }
);
type Service = { version: 1; redact(request: { version: 1; requestID: string; pieces: readonly string[] }, options: { signal: AbortSignal }): Promise<unknown> };

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}
function isExact(value: Record<string, unknown>, keys: string[]): boolean {
	return Object.keys(value).sort().join("\0") === [...keys].sort().join("\0");
}
function isPieces(value: unknown, limit: number, pieceLimit = limit): value is string[] {
	if (!Array.isArray(value) || value.length > 1000) return false;
	let total = 0;
	for (const piece of value) {
		if (typeof piece !== "string" || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(piece)) return false;
		const bytes = Buffer.byteLength(piece);
		if (bytes > pieceLimit || total > limit - bytes) return false;
		total += bytes;
	}
	return true;
}
export function sourceProtectionDigest(pieces: readonly string[]): string {
	const digest = createHash("sha256");
	for (const piece of pieces) {
		const bytes = Buffer.from(piece);
		digest.update(`${bytes.length}:`);
		digest.update(bytes);
	}
	return digest.digest("hex");
}

export async function protectDreamSources(
	pi: Pick<ExtensionAPI, "events">,
	invocationID: string,
	value: unknown,
	signal: AbortSignal,
): Promise<SourceProtectionResult> {
	if (!isRecord(value) || !isExact(value, ["version", "type", "invocationID", "requestID", "inputDigest", "pieces"])
		|| value.version !== 1 || value.type !== "sourceProtectionRequest" || value.invocationID !== invocationID
		|| typeof value.requestID !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value.requestID)
		|| typeof value.inputDigest !== "string" || !/^[a-f0-9]{64}$/.test(value.inputDigest)
		|| !isPieces(value.pieces, inputLimit, 1_048_576)
		|| sourceProtectionDigest(value.pieces) !== value.inputDigest) {
		throw new Error("Invalid private source-protection request.");
	}
	const binding: Binding = { version: 1, type: "sourceProtectionResult", invocationID, requestID: value.requestID, inputDigest: value.inputDigest };
	const block = (code: BlockedCode): SourceProtectionResult => ({ ...binding, status: "blocked", code });
	if (signal.aborted) return block("cancelled");
	const controller = new AbortController();
	const started = performance.now();
	let cancel!: () => void;
	let timer!: ReturnType<typeof setTimeout>;
	let isDiscoveryOpen = true;
	const providers: unknown[] = [];
	try {
		const interrupted = new Promise<SourceProtectionResult>((resolve) => {
			cancel = () => { controller.abort(); resolve(block("cancelled")); };
			timer = setTimeout(() => { controller.abort(); resolve(block("timeout")); }, 9000);
			signal.addEventListener("abort", cancel, { once: true });
		});
		pi.events.emit("pi-credentials:redaction-service:v1", {
			version: 1,
			signal: controller.signal,
			provide(service: unknown) {
				if (isDiscoveryOpen && providers.length < 2) providers.push(service);
			},
		});
		isDiscoveryOpen = false;
		if (signal.aborted) return block("cancelled");
		if (performance.now() - started >= 1000) return block("timeout");
		const service = providers[0];
		if (providers.length !== 1 || !isRecord(service) || service.version !== 1 || typeof service.redact !== "function") return block("not-ready");
		const pieces = [...value.pieces];
		const work = (async (): Promise<SourceProtectionResult> => {
			const result = await (service as Service).redact({ version: 1, requestID: binding.requestID, pieces }, { signal: controller.signal });
			if (signal.aborted) return block("cancelled");
			if (performance.now() - started >= 9000) return block("timeout");
			if (!isRecord(result) || result.requestID !== binding.requestID) return block("invalid-output");
			if (result.status === "blocked") {
				if (!isExact(result, ["status", "requestID", "code"]) || !codes.includes(result.code as BlockedCode)) return block("invalid-output");
				return block(result.code as BlockedCode);
			}
			if (!isExact(result, ["status", "requestID", "policy", "pieces"]) || result.status !== "checked"
				|| result.policy !== "pi-credentials/redact-v1" || !isPieces(result.pieces, outputLimit)
				|| result.pieces.length !== pieces.length) return block("invalid-output");
			const checked = [...result.pieces];
			return { ...binding, status: "checked", policy: "pi-credentials/redact-v1", pieces: checked, outputDigest: sourceProtectionDigest(checked) };
		})().catch(() => block("failed"));
		return await Promise.race([work, interrupted]);
	} catch {
		return block(signal.aborted ? "cancelled" : "failed");
	} finally {
		isDiscoveryOpen = false;
		clearTimeout(timer);
		if (cancel) signal.removeEventListener("abort", cancel);
		controller.abort();
	}
}
