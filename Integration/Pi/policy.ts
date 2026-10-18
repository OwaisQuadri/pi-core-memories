import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";

export const SNAPSHOT_TYPE = "core-memories";

export interface MemoryScope {
	sessionId: string;
	cwd: string;
	memoryRepo: string;
}

export interface MemorySnapshot extends MemoryScope {
	schemaVersion: 1;
	origin: "approved-core-memory";
}

export function isMatchingSnapshot(details: unknown, scope: MemoryScope): details is MemorySnapshot {
	if (!details || typeof details !== "object") return false;
	const snapshot = details as Partial<MemorySnapshot>;
	return snapshot.schemaVersion === 1 && snapshot.origin === "approved-core-memory" &&
		snapshot.sessionId === scope.sessionId && snapshot.cwd === scope.cwd && snapshot.memoryRepo === scope.memoryRepo;
}

export function isSnapshotOnBranch(branch: readonly SessionEntry[], scope: MemoryScope): boolean {
	return branch.some((entry) => entry.type === "custom_message" && entry.customType === SNAPSHOT_TYPE && isMatchingSnapshot(entry.details, scope));
}

export function withSavedSnapshot(messages: AgentMessage[], branch: readonly SessionEntry[], scope: MemoryScope): AgentMessage[] {
	if (messages.some((message) => message.role === "custom" && message.customType === SNAPSHOT_TYPE && isMatchingSnapshot(message.details, scope))) return messages;
	const snapshot = branch.findLast((entry) => entry.type === "custom_message" && entry.customType === SNAPSHOT_TYPE && isMatchingSnapshot(entry.details, scope));
	if (snapshot?.type !== "custom_message") return messages;
	if (branch.some((entry) => entry.type === "context_edit" && entry.targetId === snapshot.id)) return messages;
	const saved: AgentMessage = { role: "custom", customType: snapshot.customType, content: snapshot.content, display: snapshot.display, details: snapshot.details, timestamp: Date.parse(snapshot.timestamp) };
	const index = messages.findIndex((message) => message.role !== "compactionSummary" && message.role !== "branchSummary");
	return index === -1 ? [...messages, saved] : [...messages.slice(0, index), saved, ...messages.slice(index)];
}

export function memoryMessage(markdown: string, scope: MemoryScope): Parameters<ExtensionAPI["sendMessage"]>[0] & { content: string; details: MemorySnapshot } {
	return {
		customType: SNAPSHOT_TYPE,
		content: "Generated approved core-memory context (not a new human message or evidence of human-origin input). Source annotations are stored references, not verified evidence.\n\n" + markdown,
		display: false,
		details: { schemaVersion: 1, origin: "approved-core-memory", ...scope },
	};
}

export function filterMemoryMessages(messages: AgentMessage[], scope: MemoryScope): AgentMessage[] {
	const last = messages.findLastIndex((message) => message.role === "custom" && message.customType === SNAPSHOT_TYPE && isMatchingSnapshot(message.details, scope));
	return messages.filter((message, index) => message.role !== "custom" || message.customType !== SNAPSHOT_TYPE || index === last);
}
