import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { protectDreamSources, sourceProtectionDigest } from "./source-protection.ts";

function frame(pieces = ["synthetic café 🌱"]) {
	return { version: 1, type: "sourceProtectionRequest", invocationID: "fixture", requestID: "request", inputDigest: sourceProtectionDigest(pieces), pieces };
}
function bus(providers: unknown[]): Pick<ExtensionAPI, "events"> {
	return { events: { emit(channel: string, value: unknown) {
		assert.equal(channel, "pi-credentials:redaction-service:v1");
		const discovery = value as { version: number; signal: AbortSignal; provide(service: unknown): void };
		assert.deepEqual(Object.keys(discovery).sort(), ["provide", "signal", "version"]);
		for (const provider of providers) discovery.provide(provider);
	} } } as Pick<ExtensionAPI, "events">;
}
const signal = () => new AbortController().signal;

test("source protection binds UTF-8 bytes and piece boundaries before forwarding replacements", async () => {
	assert.notEqual(sourceProtectionDigest(["ab", "c"]), sourceProtectionDigest(["a", "bc"]));
	const request = frame();
	const result = await protectDreamSources(bus([{ version: 1, async redact(value: { requestID: string; pieces: readonly string[] }) {
		assert.deepEqual(value.pieces, request.pieces);
		return { status: "checked", requestID: value.requestID, policy: "pi-credentials/redact-v1", pieces: ["synthetic replacement"] };
	} }]), "fixture", request, signal());
	assert.deepEqual(result, { version: 1, type: "sourceProtectionResult", invocationID: "fixture", requestID: "request", inputDigest: request.inputDigest, status: "checked", policy: "pi-credentials/redact-v1", pieces: ["synthetic replacement"], outputDigest: sourceProtectionDigest(["synthetic replacement"]) });
});

test("wrong bindings, changed digest, duplicate fields and invalid Unicode never reach a provider", async () => {
	let calls = 0;
	const pi = bus([{ version: 1, async redact() { calls++; throw new Error("not reached"); } }]);
	for (const request of [{ ...frame(), invocationID: "other" }, { ...frame(), inputDigest: "0".repeat(64) }, { ...frame(), extra: true }, frame(["\ud800"]), frame(["x".repeat(1_048_577)])]) {
		await assert.rejects(protectDreamSources(pi, "fixture", request, signal()), { message: "Invalid private source-protection request." });
	}
	assert.equal(calls, 0);
});

test("provider exceptions and arbitrary error fields never expose private source bytes", async () => {
	const sentinel = "SYNTHETIC_PRIVATE_SOURCE_SENTINEL";
	for (const redact of [async () => { throw new Error(sentinel); }, async () => ({ status: "blocked", requestID: "request", code: "failed", error: sentinel })]) {
		const result = await protectDreamSources(bus([{ version: 1, redact }]), "fixture", frame([sentinel]), signal());
		assert.equal(result.status, "blocked");
		assert.ok(!JSON.stringify(result).includes(sentinel));
	}
});

test("cancellation revokes the provider and ignores late checked source", { timeout: 2000 }, async () => {
	const controller = new AbortController();
	let providerSignal: AbortSignal | undefined;
	let release!: (value: unknown) => void;
	const result = protectDreamSources(bus([{ version: 1, redact(_request: unknown, options: { signal: AbortSignal }) {
		providerSignal = options.signal;
		return new Promise((resolve) => { release = resolve; });
	} }]), "fixture", frame(), controller.signal);
	controller.abort();
	assert.equal((await result).status, "blocked");
	assert.equal(providerSignal?.aborted, true);
	release({ status: "checked", requestID: "request", policy: "pi-credentials/redact-v1", pieces: frame().pieces });
});
