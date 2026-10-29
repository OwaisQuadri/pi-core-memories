import { randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, opendir, realpath, unlink } from "node:fs/promises";
import { createConnection, createServer, type Socket } from "node:net";
import { dirname, join } from "node:path";

export type InteractiveState = { sessionID: string; isForeground: boolean };
export type InteractiveSnapshot = { sessionIDs: string[]; isForeground: boolean };
export type InteractiveMembership = {
	set(state: InteractiveState): void;
	snapshot(): Promise<InteractiveSnapshot>;
	close(): Promise<void>;
};
function blocked(): never { throw new Error("Interactive memory membership is unavailable or ambiguous."); }
function validState(value: unknown): InteractiveState {
	if (!value || typeof value !== "object" || Array.isArray(value)) return blocked();
	const state = value as Record<string, unknown>;
	if (Object.keys(state).sort().join() !== "isForeground,sessionID" || typeof state.sessionID !== "string" || !/^[A-Za-z0-9._:-]{1,256}$/.test(state.sessionID) || typeof state.isForeground !== "boolean") return blocked();
	return { sessionID: state.sessionID, isForeground: state.isForeground };
}
export async function joinInteractiveMembership(directory: string, initial: InteractiveState, onChanged: (snapshot?: InteractiveSnapshot) => void): Promise<InteractiveMembership> {
	const uid = process.getuid?.();
	if (uid === undefined) return blocked();
	await mkdir(dirname(directory), { recursive: true, mode: 0o700 });
	const parent = await lstat(dirname(directory));
	if (!parent.isDirectory() || parent.uid !== uid || (parent.mode & 0o022) !== 0) return blocked();
	await mkdir(directory, { mode: 0o700 }).catch((error: NodeJS.ErrnoException) => { if (error.code !== "EEXIST") throw error; });
	const root = await lstat(directory);
	if (!root.isDirectory() || root.uid !== uid || (root.mode & 0o777) !== 0o700 || await realpath(directory) !== directory) return blocked();
	const name = `${process.pid}-${randomUUID()}.sock`;
	const path = join(directory, name);
	if (Buffer.byteLength(path) > 100) return blocked();
	let state = validState(initial);
	let isClosed = false;
	let isPolling = false;
	let prior: string | undefined;
	const connections = new Set<Socket>();
	const server = createServer((socket) => {
		connections.add(socket);
		socket.on("error", () => {});
		socket.once("close", () => connections.delete(socket));
		if (connections.size > 128 || isClosed) { socket.destroy(); return; }
		socket.setTimeout(200, () => socket.destroy());
		socket.end(JSON.stringify(state) + "\n");
	});
	await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(path, () => { server.removeListener("error", reject); resolve(); }); });
	try { await chmod(path, 0o600); }
	catch (error) { await new Promise<void>((resolve) => server.close(() => resolve())); throw error; }
	const own = await lstat(path);
	let isFailed = false;
	server.on("error", () => { isFailed = true; onChanged(); });
	async function checkRoot(): Promise<void> {
		const current = await lstat(directory);
		if (isClosed || isFailed || current.dev !== root.dev || current.ino !== root.ino || current.uid !== uid || !current.isDirectory() || (current.mode & 0o777) !== 0o700) return blocked();
	}
	async function memberNames(): Promise<string[]> {
		const names: string[] = [];
		for await (const entry of await opendir(directory)) { names.push(entry.name); if (names.length > 64) return blocked(); }
		return names.sort();
	}
	async function readMember(member: string): Promise<InteractiveState | undefined> {
		const identity = /^([1-9][0-9]{0,9})-[a-f0-9-]{36}\.sock$/.exec(member);
		if (!identity || Number(identity[1]) > 2_147_483_647) return blocked();
		const location = join(directory, member);
		const metadata = await lstat(location);
		if (!metadata.isSocket() || metadata.uid !== uid || metadata.nlink !== 1 || (metadata.mode & 0o777) !== 0o600) return blocked();
		try {
			return await new Promise<InteractiveState>((resolve, reject) => {
				const socket = createConnection(location);
				let text = "";
				const timer = setTimeout(() => { socket.destroy(); reject(new Error("Interactive peer did not answer.")); }, 200);
				socket.on("error", (error) => { clearTimeout(timer); reject(error); });
				socket.on("data", (chunk: Buffer) => { text += chunk.toString("utf8"); if (Buffer.byteLength(text) > 1024) { clearTimeout(timer); socket.destroy(); reject(new Error("Oversized interactive peer.")); } });
				socket.on("end", () => {
					clearTimeout(timer); socket.destroy();
					try { if (!text.endsWith("\n") || text.indexOf("\n") !== text.length - 1) return reject(new Error("Invalid interactive peer.")); resolve(validState(JSON.parse(text))); }
					catch (error) { reject(error); }
				});
			});
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ECONNREFUSED") throw error;
			try { process.kill(Number(identity[1]), 0); return blocked(); }
			catch (probe) { if ((probe as NodeJS.ErrnoException).code !== "ESRCH") return blocked(); }
			const current = await lstat(location);
			if (current.ino !== metadata.ino || current.dev !== metadata.dev || !current.isSocket() || current.uid !== uid) return blocked();
			await unlink(location);
			return undefined;
		}
	}
	async function snapshot(): Promise<InteractiveSnapshot> {
		await checkRoot();
		const names = await memberNames();
		if (names.length > 64 || !names.includes(name)) return blocked();
		const members = (await Promise.all(names.map(readMember))).filter((value): value is InteractiveState => value !== undefined);
		await checkRoot();
		const after = await memberNames();
		if (after.some((member) => !names.includes(member))) return blocked();
		if (!members.some((member) => member.sessionID === state.sessionID)) return blocked();
		return { sessionIDs: [...new Set(members.map((member) => member.sessionID))].sort(), isForeground: members.some((member) => member.isForeground) };
	}
	const timer = setInterval(() => {
		if (isPolling || isClosed) return;
		isPolling = true;
		void snapshot().then((value) => { const next = JSON.stringify(value); if (prior !== next || value.isForeground) onChanged(value); prior = next; }, () => { prior = undefined; onChanged(); }).finally(() => { isPolling = false; });
	}, 200);
	timer.unref(); server.unref();
	return {
		set(value) { state = validState(value); },
		snapshot,
		async close() {
			if (isClosed) return;
			isClosed = true; clearInterval(timer); onChanged();
			for (const socket of connections) socket.destroy();
			await new Promise<void>((resolve) => server.close(() => resolve()));
			try { const current = await lstat(path); if (current.ino === own.ino && current.dev === own.dev && current.isSocket()) await unlink(path); }
			catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
		},
	};
}
