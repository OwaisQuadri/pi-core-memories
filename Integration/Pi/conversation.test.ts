import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { askMemoryDecision } from "./conversation.ts";

type Question = { onPresented: () => Promise<void>; requestId: string; signal: AbortSignal; params: { question: string; details: string; policy: { kind: string } } };
const preview = { candidateID: "a".repeat(64), digest: "b".repeat(64), details: "Finding: prefer direct checks.\nReason: explicit lasting intent.\nEvidence: synthetic session, entry 7." };

function fixture(answer: (question: Question) => unknown, isRendered = true, isServiceAvailable = true) {
	const listeners = new Map<string, Set<(value: unknown) => void>>();
	let question: Question | undefined;
	const emit = (name: string, value: unknown) => {
		for (const handler of listeners.get(name) ?? []) handler(value);
		if (name === "ask-user-question:rpc:ping") {
			const request = value as { requestId: string };
			emit(`${name}:reply:${request.requestId}`, { success: isServiceAvailable, data: { version: 1 } });
		}
		if (name === "ask-user-question:rpc:ask") {
			question = value as Question;
			const current = question;
			const respond = () => {
				const response = answer(current);
				if (response !== undefined) emit(`${name}:reply:${current.requestId}`, response);
			};
			if (isRendered) void current.onPresented().then(respond).catch(() => {});
			else respond();
		}
	};
	const events = {
		on(name: string, handler: (value: unknown) => void) {
			const handlers = listeners.get(name) ?? new Set();
			handlers.add(handler);
			listeners.set(name, handlers);
			return () => { handlers.delete(handler); };
		},
		emit,
	};
	const pi = { events } as unknown as ExtensionAPI;
	const ctx = { mode: "tui", hasUI: true, sessionManager: { getSessionId: () => "fixture-session" } } as unknown as ExtensionContext;
	return { pi, ctx, get question() { return question; }, get listenerCount() { return [...listeners.values()].reduce((total, handlers) => total + handlers.size, 0); } };
}

function human(question: Question, value: string) {
	return { success: true, data: { details: {
		status: "answered", provenance: "interactive-user", question: question.params.question,
		context: question.params.details, mode: "single-select", answers: [{ type: "option", value }],
	} } };
}

test("only exact human question choices can decide the displayed memory version", async () => {
	for (const choice of ["approve", "reject", "defer"] as const) {
		const f = fixture((question) => human(question, choice));
		assert.equal(await askMemoryDecision(f.pi, f.ctx, preview, new AbortController().signal, () => true), choice);
		assert.equal(f.question?.params.policy.kind, "approval");
		assert.equal(f.question?.params.details, `${preview.details}\n\nProposal: ${preview.candidateID}\nExact version: ${preview.digest}`);
		assert.equal(f.listenerCount, 0);
	}
});

test("policy guidance and altered proposal displays cannot become memory approval", async () => {
	for (const replacement of [{ provenance: "automatic-policy-guidance" }, { context: "another proposal" }, { question: "another question" }]) {
		const f = fixture((question) => {
			const result = human(question, "approve");
			Object.assign(result.data.details, replacement);
			return result;
		});
		await assert.rejects(askMemoryDecision(f.pi, f.ctx, preview, new AbortController().signal, () => true), /No matching human memory decision/);
		assert.equal(f.listenerCount, 0);
	}
});

test("cancellation and a replaced request release question listeners without approval", async () => {
	const f = fixture(() => undefined);
	const controller = new AbortController();
	const pending = askMemoryDecision(f.pi, f.ctx, preview, controller.signal, () => true);
	await setImmediate();
	assert.ok(f.question);
	controller.abort();
	assert.equal(await pending, "cancelled");
	assert.equal(f.question.signal.aborted, true);
	assert.equal(f.listenerCount, 0);
	let isCurrent = true;
	const replaced = fixture((question) => { isCurrent = false; return human(question, "approve"); });
	assert.equal(await askMemoryDecision(replaced.pi, replaced.ctx, preview, new AbortController().signal, () => isCurrent), "cancelled");
	assert.equal(replaced.listenerCount, 0);
});

test("answers before rendered native acknowledgement never approve", async () => {
	const premature = fixture((question) => human(question, "approve"), false);
	await assert.rejects(askMemoryDecision(premature.pi, premature.ctx, preview, new AbortController().signal, () => true), /No matching human memory decision/);
	let acknowledge!: () => void;
	const gate = new Promise<void>((resolve) => { acknowledge = resolve; });
	let isAnswered = false;
	const waiting = fixture((question) => { isAnswered = true; return human(question, "approve"); });
	const pending = askMemoryDecision(waiting.pi, waiting.ctx, preview, new AbortController().signal, () => true, { onPresented: () => gate });
	await setImmediate();
	assert.equal(isAnswered, false);
	acknowledge();
	assert.equal(await pending, "approve");
});

test("failed native presentation acknowledgement releases listeners without consent", async () => {
	const f = fixture(() => assert.fail("An answer cannot follow failed display acknowledgement"));
	await assert.rejects(askMemoryDecision(f.pi, f.ctx, preview, new AbortController().signal, () => true, { onPresented: async () => { throw new Error("synthetic failure"); } }), /display acknowledgement failed/);
	assert.equal(f.listenerCount, 0);
});

test("exact leading and trailing proposal bytes survive the question service", async () => {
	const exact = { ...preview, details: `  ${preview.details}\n\n` };
	const f = fixture((question) => human(question, "defer"));
	assert.equal(await askMemoryDecision(f.pi, f.ctx, exact, new AbortController().signal, () => true), "defer");
	assert.ok(f.question!.params.details.startsWith(exact.details));
});

test("missing question service and oversized proposals fail closed", async () => {
	const missing = fixture(() => assert.fail("No question service"), true, false);
	await assert.rejects(askMemoryDecision(missing.pi, missing.ctx, preview, new AbortController().signal, () => true), /question service is unavailable/);
	assert.equal(missing.question, undefined);
	const oversized = fixture(() => assert.fail("Oversized proposal cannot render"));
	await assert.rejects(askMemoryDecision(oversized.pi, oversized.ctx, { ...preview, details: "x".repeat(65_537) }, new AbortController().signal, () => true), /cannot be safely shown/);
});
