import { randomUUID } from "node:crypto";
import { lstat, mkdir, open, opendir, readFile, realpath, rename, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";

export type LiveSessionMarker = { close(): Promise<void> };
const sessionPattern = /^[A-Za-z0-9._:-]{1,256}$/;
const markerPattern = /^([1-9][0-9]{0,9})-[a-f0-9-]{36}\.live$/;
function blocked(): never { throw new Error("Live session markers are unavailable or unsafe."); }

async function checkedDirectory(directory: string): Promise<number> {
	const uid = process.getuid?.();
	if (uid === undefined) return blocked();
	await mkdir(dirname(directory), { recursive: true, mode: 0o700 });
	const parent = await lstat(dirname(directory));
	if (!parent.isDirectory() || parent.uid !== uid || (parent.mode & 0o022) !== 0) return blocked();
	await mkdir(directory, { mode: 0o700 }).catch((error: NodeJS.ErrnoException) => { if (error.code !== "EEXIST") throw error; });
	const root = await lstat(directory);
	if (!root.isDirectory() || root.uid !== uid || (root.mode & 0o777) !== 0o700 || await realpath(directory) !== directory) return blocked();
	return uid;
}

function isProcessAlive(pid: number): boolean {
	try { process.kill(pid, 0); return true; }
	catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

export async function markLiveSession(directory: string, sessionID: string): Promise<LiveSessionMarker> {
	if (!sessionPattern.test(sessionID)) return blocked();
	await checkedDirectory(directory);
	const path = join(directory, `${process.pid}-${randomUUID()}.live`);
	const staging = path + ".tmp";
	const file = await open(staging, "wx", 0o600);
	try { await file.writeFile(sessionID); } finally { await file.close(); }
	await rename(staging, path);
	const own = await lstat(path);
	let isClosed = false;
	return {
		async close() {
			if (isClosed) return;
			isClosed = true;
			try { const current = await lstat(path); if (current.ino === own.ino && current.dev === own.dev) await unlink(path); }
			catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
		},
	};
}

export async function liveSessionIDs(directory: string): Promise<string[]> {
	const uid = await checkedDirectory(directory);
	const sessions = new Set<string>();
	let count = 0;
	for await (const entry of await opendir(directory)) {
		const identity = markerPattern.exec(entry.name);
		if (!identity) continue;
		if (++count > 256) return blocked();
		const location = join(directory, entry.name);
		const metadata = await lstat(location).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
		if (!metadata) continue;
		if (!metadata.isFile() || metadata.uid !== uid || metadata.nlink !== 1 || (metadata.mode & 0o777) !== 0o600 || metadata.size > 256) return blocked();
		if (!isProcessAlive(Number(identity[1]))) { await unlink(location).catch(() => {}); continue; }
		const sessionID = await readFile(location, "utf8").catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
		if (sessionID === undefined) continue;
		if (!sessionPattern.test(sessionID)) return blocked();
		sessions.add(sessionID);
	}
	return [...sessions].sort();
}
