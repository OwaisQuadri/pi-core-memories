import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { askMemoryDecision } from "./conversation.ts";

type Question = { requestId: string; signal: AbortSignal; params: { question: string; details: string; policy: { kind: string } } };
const preview = { candidateID: "a".repeat(64), digest: "b".repeat(64), details: "Finding: prefer direct checks.\nReason: explicit lasting intent.\nEvidence: synthetic session, entry 7." };

function fixture(answer: (question: Question) => unknown) {
	const listeners = new Map<string, Set<(value: unknown) => void>>();
	let question: Question | undefined;
	const emit = (name: string, value: unknown) => {
		for (const handler of listeners.get(name) ?? []) handler(value);
		if (name === "ask-user-question:rpc:ping") {
			const request = value as { requestId: string };
			emit(`${name}:reply:${request.requestId}`, { success: true, data: { version: 1 } });
		}
		if (name === "ask-user-question:rpc:ask") {
			question = value as Question;
			const response = answer(question);
			if (response !== undefined) emit(`${name}:reply:${question.requestId}`, response);
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
