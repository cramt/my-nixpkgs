// Brings a running T3 Code server's projects and scheduled tasks in line with
// a declared spec (written by nixosModules.t3code). It manages only what it
// declares: everything it creates gets a `nix:<name>` id, so there's no state
// file, and anything made in the UI is never deleted.
//
// It talks to the same APIs the web client does, with a short-lived bearer
// session from `t3 auth session issue`:
//  - projects over HTTP (`/api/projects`, `/api/projects/mutate`)
//  - scheduled tasks over the WebSocket RPC (`scheduledTasks.*`), which has
//    no HTTP equivalent
// Not over `/mcp`: its project tools refuse anything short of a full-access
// client, and `schedule_task` copies the caller's runtime mode, which for a
// CLI-issued session is approval-required, so unattended runs would block on
// their first tool call.

import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";

const run = promisify(execFile);

// ---------------------------------------------------------------- spec

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

type ModelSelection = { instanceId: string; model: string; options?: Json };

type Schedule =
  | { type: "interval"; everyMs: number }
  | { type: "fixed_time"; timeOfDay: string; weekdays?: number[] }
  | { type: "once"; runAt: string };

type WorkspaceStrategy =
  | { type: "root"; branch?: string }
  | { type: "worktree"; baseRef: string; branch?: string; startFromOrigin?: boolean };

type RuntimeMode = "approval-required" | "auto-accept-edits" | "auto" | "full-access";

type ProjectSpec = {
  workspaceRoot: string;
  title: string;
  createWorkspaceRootIfMissing: boolean;
  // Merged into project.update verbatim (autoPull, pinned, scripts,
  // defaultModelSelection, projectIcon, ...); the server validates them.
  settings: { [k: string]: Json };
};

type TaskSpec = {
  title: string;
  prompt: string;
  enabled: boolean;
  schedule: Schedule;
  // A workspaceRoot. The project may be declared here or made in the UI.
  project: string;
  modelSelection: ModelSelection;
  runtimeMode: RuntimeMode;
  interactionMode: "default" | "plan";
  workspaceStrategy: WorkspaceStrategy;
};

type Spec = {
  origin: string;
  baseDir: string;
  t3: string;
  readyTimeoutSeconds: number;
  projects: { [name: string]: ProjectSpec };
  scheduledTasks: { [name: string]: TaskSpec };
};

// Names are attr names the module restricts to [A-Za-z0-9_-], so they never
// contain the separator.
const ID_PREFIX = "nix:";
const taskId = (name: string): string => `${ID_PREFIX}${name}`;
// Projects are event-sourced: a deleted project's id is spent for good
// ("already exists and cannot be created twice"), so each creation gets a
// fresh suffix and ownership is read off the name part.
const newProjectId = (name: string): string => `${ID_PREFIX}${name}:${randomUUID().slice(0, 8)}`;
const ownerName = (id: string): string | undefined =>
  id.startsWith(ID_PREFIX) ? id.slice(ID_PREFIX.length).split(":")[0] : undefined;

// ---------------------------------------------------------------- auth

type Session = { token: string; sessionId: string };

async function issueSession(spec: Spec): Promise<Session> {
  const { stdout } = await run(spec.t3, [
    "auth", "session", "issue",
    "--base-dir", spec.baseDir,
    "--scope", "orchestration:read",
    "--scope", "orchestration:operate",
    "--ttl", "10m",
    "--label", "t3code-declare",
    "--json",
  ]).catch((err: { stderr?: string; message: string }) => {
    throw new Error(`t3 auth session issue failed: ${err.stderr?.trim() || err.message}`);
  });
  const issued = JSON.parse(stdout) as { token?: string; sessionId?: string };
  if (!issued.token || !issued.sessionId) throw new Error(`t3 auth session issue gave no token: ${stdout}`);
  return { token: issued.token, sessionId: issued.sessionId };
}

async function revokeSession(spec: Spec, session: Session): Promise<void> {
  await run(spec.t3, ["auth", "session", "revoke", "--base-dir", spec.baseDir, session.sessionId]).catch(
    (err: unknown) => console.warn(`could not revoke session ${session.sessionId}: ${String(err)}`),
  );
}

async function waitForServer(spec: Spec): Promise<void> {
  const deadline = Date.now() + spec.readyTimeoutSeconds * 1000;
  for (;;) {
    let why: string;
    try {
      // 401 means up. A 5xx means still starting: it answers 503 while it
      // migrates the database, and `t3 auth session issue` fails until then.
      const res = await fetch(new URL("/api/projects", spec.origin));
      await res.body?.cancel();
      if (res.status < 500) return;
      why = `HTTP ${res.status}`;
    } catch (err) {
      why = String(err);
    }
    if (Date.now() > deadline) throw new Error(`server at ${spec.origin} not ready: ${why}`);
    await new Promise((r) => setTimeout(r, 1000));
  }
}

// ---------------------------------------------------------------- HTTP

async function http<T>(spec: Spec, token: string, path: string, body?: object): Promise<T> {
  const res = await fetch(new URL(path, spec.origin), {
    method: body === undefined ? "GET" : "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status} ${text}`);
  return JSON.parse(text) as T;
}

// ---------------------------------------------------------------- WS RPC

type RpcMessage =
  | { _tag: "Chunk"; requestId: string; values: unknown[] }
  | { _tag: "Exit"; requestId: string; exit: { _tag: "Success"; value: unknown } | { _tag: "Failure"; cause: unknown } }
  | { _tag: "Pong" | "Defect" | "ClientProtocolError"; requestId?: undefined };

class Rpc {
  private nextId = 1;
  private readonly pending = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();

  private constructor(private readonly ws: WebSocket) {
    ws.onmessage = (event) => {
      const msg = JSON.parse(String(event.data)) as RpcMessage;
      if (msg.requestId === undefined) return;
      const waiter = this.pending.get(msg.requestId);
      if (!waiter) return;
      this.pending.delete(msg.requestId);
      if (msg._tag === "Chunk") {
        // Streams (subscribe) open with a full snapshot; that's all we read.
        waiter.resolve(msg.values[0]);
      } else if (msg.exit._tag === "Success") {
        waiter.resolve(msg.exit.value);
      } else {
        waiter.reject(new Error(JSON.stringify(msg.exit.cause)));
      }
    };
    ws.onclose = () => {
      for (const w of this.pending.values()) w.reject(new Error("WebSocket closed"));
      this.pending.clear();
    };
  }

  static async connect(spec: Spec, token: string): Promise<Rpc> {
    const { ticket } = await http<{ ticket: string }>(spec, token, "/api/auth/websocket-ticket/rpc", {});
    const url = new URL("/ws", spec.origin);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    // The server's ORCHESTRATION_PROTOCOL_VERSION; any other answers 426.
    url.searchParams.set("orchestrationProtocol", "2");
    url.searchParams.set("wsTicket", ticket);
    const ws = new WebSocket(url);
    await new Promise<void>((resolve, reject) => {
      ws.onopen = () => resolve();
      ws.onerror = () => reject(new Error(`WebSocket to ${spec.origin} failed`));
    });
    return new Rpc(ws);
  }

  request<T>(tag: string, payload: object): Promise<T> {
    const id = String(this.nextId++);
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.ws.send(JSON.stringify({ _tag: "Request", id, tag, payload, headers: [] }));
    });
  }

  close(): void {
    this.ws.close();
  }
}

// ---------------------------------------------------------------- reconcile

type Project = { id: string; title: string; workspaceRoot: string; deletedAt: string | null };

const projectMutate = (spec: Spec, token: string, mutation: object) =>
  http<Project>(spec, token, "/api/projects/mutate", { commandId: randomUUID(), ...mutation });

async function liveProjects(spec: Spec, token: string): Promise<Project[]> {
  const { projects } = await http<{ projects: Project[] }>(spec, token, "/api/projects");
  return projects.filter((p) => p.deletedAt === null);
}

// Creates and updates only. Removal waits until after the tasks, so a
// project is never deleted out from under a task that still points at it.
async function applyProjects(spec: Spec, token: string): Promise<Map<string, string>> {
  const mutate = (mutation: object) => projectMutate(spec, token, mutation);
  const live = await liveProjects(spec, token);
  const ours = new Map(live.flatMap((p) => {
    const name = ownerName(p.id);
    return name === undefined ? [] : [[name, p] as const];
  }));
  const byRoot = new Map(live.map((p) => [p.workspaceRoot, p]));

  for (const [name, want] of Object.entries(spec.projects)) {
    // Ours first, so moving a declared project's folder updates it in place.
    // Otherwise a folder registered by hand is taken over, not duplicated:
    // it keeps its own id, so dropping the declaration later leaves it be.
    let project = ours.get(name) ?? byRoot.get(want.workspaceRoot);
    if (!project) {
      project = await mutate({
        type: "project.create",
        projectId: newProjectId(name),
        title: want.title,
        workspaceRoot: want.workspaceRoot,
        createWorkspaceRootIfMissing: want.createWorkspaceRootIfMissing,
      });
      console.log(`project ${name}: created at ${want.workspaceRoot}`);
    }
    project = await mutate({
      type: "project.update",
      projectId: project.id,
      title: want.title,
      workspaceRoot: want.workspaceRoot,
      ...want.settings,
    });
    byRoot.set(project.workspaceRoot, project);
    console.log(`project ${name}: ${project.workspaceRoot} (${project.id}) up to date`);
  }

  return new Map([...byRoot].map(([root, p]) => [root, p.id]));
}

async function removeStaleProjects(spec: Spec, token: string): Promise<void> {
  const mutate = (mutation: object) => projectMutate(spec, token, mutation);
  for (const project of await liveProjects(spec, token)) {
    const name = ownerName(project.id);
    if (name === undefined || name in spec.projects) continue;
    // Deleting a project with threads needs force; those threads are someone's
    // work, so archive it instead.
    try {
      await mutate({ type: "project.delete", projectId: project.id });
      console.log(`project ${project.id}: no longer declared, deleted`);
    } catch {
      await mutate({ type: "project.update", projectId: project.id, archived: true });
      console.log(`project ${project.id}: no longer declared but has threads, archived`);
    }
  }
}

async function reconcileTasks(spec: Spec, rpc: Rpc, projectIds: Map<string, string>): Promise<void> {
  const { tasks } = await rpc.request<{ tasks: { id: string }[] }>("scheduledTasks.subscribe", {});

  for (const [name, want] of Object.entries(spec.scheduledTasks)) {
    const projectId = projectIds.get(want.project);
    if (!projectId) throw new Error(`scheduled task ${name}: no project at ${want.project}`);
    // The server keeps next_run_at while the schedule is unchanged, so
    // re-applying this on every start doesn't postpone a due run.
    await rpc.request("scheduledTasks.upsert", {
      id: taskId(name),
      title: want.title,
      prompt: want.prompt,
      enabled: want.enabled,
      schedule: want.schedule,
      projectId,
      threadId: null,
      workspaceStrategy: want.workspaceStrategy,
      modelSelection: want.modelSelection,
      runtimeMode: want.runtimeMode,
      interactionMode: want.interactionMode,
      creationSource: "server",
    });
    console.log(`scheduled task ${name}: up to date`);
  }

  for (const task of tasks) {
    const name = ownerName(task.id);
    if (name === undefined || name in spec.scheduledTasks) continue;
    await rpc.request("scheduledTasks.delete", { id: task.id });
    console.log(`scheduled task ${task.id}: no longer declared, deleted`);
  }
}

// ---------------------------------------------------------------- main

async function main(): Promise<void> {
  const specPath = process.argv[2];
  if (!specPath) throw new Error("usage: t3code-declare <spec.json>");
  const spec = JSON.parse(await readFile(specPath, "utf8")) as Spec;

  await waitForServer(spec);
  const session = await issueSession(spec);
  let rpc: Rpc | undefined;
  try {
    const projectIds = await applyProjects(spec, session.token);
    rpc = await Rpc.connect(spec, session.token);
    await reconcileTasks(spec, rpc, projectIds);
    await removeStaleProjects(spec, session.token);
  } finally {
    rpc?.close();
    await revokeSession(spec, session);
  }
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
