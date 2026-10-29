#!/usr/bin/env node
// Generates docs/design/api-shapes.md (design section 8.9): one row per
// endpoint the console's API client calls, with the method, the query or
// body keys, the TypeScript response type, the Go handler file:line, the
// scope its route wrapper requires and the scopes the handler itself checks.
// Endpoints the v3 design names that the console never calls get rows from
// the Go side alone, so the table covers every endpoint the design uses.
//
// Usage: node scripts/api-shapes.mjs [--dashboard DIR] [--server DIR] [--out FILE]
// Defaults assume the Lattice working desk layout: ../lattice-dashboard and
// ../lattice-server next to the Astra checkout (or two levels up from a
// worktree under .worktrees/).

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");

function argument(name) {
  const index = process.argv.indexOf(name);
  return index > 0 ? process.argv[index + 1] : undefined;
}

function findSibling(name) {
  for (const base of [resolve(repo, ".."), resolve(repo, "../.."), resolve(repo, "../../..")]) {
    const candidate = join(base, name);
    if (existsSync(candidate)) return candidate;
  }
  throw new Error(`cannot find ${name} next to ${repo}; pass --dashboard and --server`);
}

const dashboard = resolve(argument("--dashboard") ?? findSibling("lattice-dashboard"));
const server = resolve(argument("--server") ?? findSibling("lattice-server"));
const out = resolve(argument("--out") ?? join(repo, "docs/design/api-shapes.md"));
const design = join(repo, "docs/design/astra-v3-design.md");

// ---------------------------------------------------------------------------
// Console client: lib/api/index.ts

function balanced(text, start, open, close) {
  // Returns the index just past the bracket that closes the one at `start`.
  let depth = 0;
  let quote = null;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    if (quote) {
      if (ch === "\\") i += 1;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") quote = ch;
    else if (ch === "=" && text[i + 1] === ">") i += 1; // an arrow is not a closing angle bracket
    else if (ch === open) depth += 1;
    else if (ch === close) {
      depth -= 1;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

function splitArguments(text) {
  const parts = [];
  let depth = 0;
  let quote = null;
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (quote) {
      if (ch === "\\") i += 1;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") quote = ch;
    else if (ch === "=" && text[i + 1] === ">") i += 1;
    else if ("([{<".includes(ch)) depth += 1;
    else if (")]}>".includes(ch)) depth -= 1;
    else if (ch === "," && depth === 0) {
      parts.push(text.slice(start, i).trim());
      start = i + 1;
    }
  }
  const last = text.slice(start).trim();
  if (last) parts.push(last);
  return parts;
}

function objectKeys(literal) {
  // Top-level keys of an object literal, or the expression itself.
  const text = literal.trim();
  if (!text.startsWith("{")) return text;
  const inner = text.slice(1, -1);
  const keys = splitArguments(inner)
    .map((part) => part.replace(/^\.\.\./, "...").split(":")[0].trim())
    .filter(Boolean)
    .map((key) => key.replace(/\?$/, ""));
  return keys.length ? `{${keys.join(", ")}}` : "{}";
}

function normalizePath(raw) {
  // "/api/x" or `/api/x/${encodeURIComponent(id)}/rotate?kind=${kind}`
  // -> { path: "/api/x/{id}/rotate", query: ["kind"] }
  const text = raw
    .slice(1, -1)
    .replace(/\$\{([^}]*)\}/g, (_, expr) => {
      const name = expr.replace(/encodeURIComponent\(|\)|String\(/g, "").split(".").pop().trim();
      return `{${name || "param"}}`;
    });
  const [path, search = ""] = text.split("?");
  const query = search ? search.split("&").map((pair) => pair.split("=")[0]).filter(Boolean) : [];
  return { path, query };
}

function consoleCalls() {
  const source = readFileSync(join(dashboard, "src/lib/api/index.ts"), "utf8");
  const calls = [];
  const pattern = /http\.(get|post|put|patch|del)\b/g;
  let match;
  while ((match = pattern.exec(source))) {
    const method = { get: "GET", post: "POST", put: "PUT", patch: "PATCH", del: "DELETE" }[match[1]];
    let cursor = match.index + match[0].length;
    while (/\s/.test(source[cursor])) cursor += 1;
    let type = "";
    if (source[cursor] === "<") {
      const end = balanced(source, cursor, "<", ">");
      type = source.slice(cursor + 1, end - 1).replace(/\s+/g, " ").trim();
      cursor = end;
    }
    while (/\s/.test(source[cursor])) cursor += 1;
    if (source[cursor] !== "(") continue;
    const end = balanced(source, cursor, "(", ")");
    const args = splitArguments(source.slice(cursor + 1, end - 1));
    const rawPath = args[0] ?? "";
    if (!/^["`]\/api\//.test(rawPath)) continue;
    const line = source.slice(0, match.index).split("\n").length;
    const second = args[1];
    const { path, query } = normalizePath(rawPath);
    let payload = second && second !== "undefined" ? objectKeys(second) : "";
    if (query.length) payload = [`?${query.join("&")}`, payload].filter(Boolean).join(" ");
    calls.push({ method, path, type: type || "void", payload, line });
  }
  return calls;
}

// ---------------------------------------------------------------------------
// Server routes and handlers: internal/server

function goFiles() {
  const dir = join(server, "internal/server");
  return readdirSync(dir)
    .filter((name) => name.endsWith(".go") && !name.endsWith("_test.go"))
    .map((name) => ({ name, path: join(dir, name), text: readFileSync(join(dir, name), "utf8") }));
}

function serverRoutes(files) {
  const routes = [];
  for (const file of files) {
    const lines = file.text.split("\n");
    lines.forEach((text, index) => {
      const route = /mux\.HandleFunc\("([^"]+)",\s*(.*)\)\s*$/.exec(text.trim())
        ?? /mux\.HandleFunc\("([^"]+)",\s*(func\(.*)$/.exec(text.trim());
      if (!route) return;
      const expr = route[2];
      if (expr.startsWith("func(")) {
        routes.push({ pattern: route[1], wrapper: "public", handler: "", at: `${file.name}:${index + 1}` });
        return;
      }
      const scope = /withAuth\("([^"]*)"/.exec(expr);
      const handlers = [...expr.matchAll(/s\.(handle\w+)/g)].map((m) => m[1]);
      routes.push({
        pattern: route[1],
        wrapper: scope ? (scope[1] || "signed in") : expr.includes("withAgentLimit") ? "agent" : "public",
        handler: handlers[handlers.length - 1] ?? "",
        at: `server.go:${index + 1}`.replace("server.go", file.name),
      });
    });
  }
  return routes;
}

function scopeLiterals(body) {
  return [...body.matchAll(/"([a-z]+:[a-z*]+)"/g)].map((m) => m[1]).filter((scope) => !/^(https?|tcp|udp|unix|data|file):/.test(scope));
}

function handlerIndex(files) {
  // Every Server method with its own scope literals; a handler's scopes
  // include those of the Server methods it calls directly (one level), so
  // a check made in a helper such as upsertMaintenanceWindow is listed.
  const methods = new Map();
  for (const file of files) {
    const lines = file.text.split("\n");
    lines.forEach((text, i) => {
      const found = /^func \(s \*Server\) (\w+)\(/.exec(text);
      if (!found) return;
      let end = i + 1;
      while (end < lines.length && !/^func /.test(lines[end])) end += 1;
      const body = lines.slice(i, end).join("\n");
      const calls = [...new Set([...body.matchAll(/\bs\.([a-z]\w*)\(/g)].map((m) => m[1]))];
      methods.set(found[1], { at: `${file.name}:${i + 1}`, own: scopeLiterals(body), calls });
    });
  }
  const index = new Map();
  for (const [name, method] of methods) {
    if (!name.startsWith("handle")) continue;
    const scopes = new Set(method.own);
    for (const callee of method.calls) for (const scope of methods.get(callee)?.own ?? []) scopes.add(scope);
    index.set(name, { at: method.at, scopes: [...scopes] });
  }
  return index;
}

function routeFor(routes, path) {
  // Exact match first, then the longest subtree pattern ending in "/".
  const bare = path.replace(/\{[^}]*\}/g, "x");
  const exact = routes.find((route) => route.pattern === path || route.pattern === bare);
  if (exact) return exact;
  return routes
    .filter((route) => route.pattern.endsWith("/") && bare.startsWith(route.pattern))
    .sort((a, b) => b.pattern.length - a.pattern.length)[0];
}

// ---------------------------------------------------------------------------
// Endpoints the design names

function designEndpoints() {
  const text = readFileSync(design, "utf8");
  const named = new Map();
  const add = (method, path) => named.set(`${method} ${path}`, { method, path });
  for (const m of text.matchAll(/\b(GET|POST|PUT|PATCH|DELETE)\s+`?(\/api\/[A-Za-z0-9_\-/{}.]+)/g)) {
    add(m[1], m[2].replace(/[.,]+$/, ""));
  }
  // The endpoint ownership table of section 8.4: "GET `me`, `version`; POST `incidents/ack`, `/unack`".
  for (const line of text.split("\n")) {
    const row = /^\| (Shared \(M0a\)|M\d+) \| (.*) \|$/.exec(line);
    if (!row) continue;
    let methods = [];
    let previous = "";
    for (const m of row[2].matchAll(/((?:GET|POST|PUT|PATCH|DELETE)(?:\s+and\s+(?:GET|POST|PUT|PATCH|DELETE))*)|`([^`]+)`/g)) {
      if (m[1]) {
        methods = m[1].split(/\s+and\s+/);
        continue;
      }
      let path = m[2];
      if (!/^\/?[a-z][a-z0-9\-/{},]*$/.test(path) || !methods.length) continue;
      if (path.startsWith("/") && previous) path = previous.replace(/\/[^/]*$/, "") + path;
      previous = path.replace(/^\//, "");
      const brace = /\{([^}]*,[^}]*)\}/.exec(previous);
      const expanded = brace ? brace[1].split(",").map((part) => previous.replace(brace[0], part)) : [previous];
      for (const candidate of expanded) for (const method of methods) add(method, `/api/${candidate}`);
    }
  }
  return [...named.values()];
}

// ---------------------------------------------------------------------------
// Notes

const ENVELOPE_ON_QUERY = new Map([
  ["/api/tasks", "bare array without query parameters, {tasks, total, limit, offset} with any"],
  ["/api/audit", "bare array without query parameters, {events, total, limit, offset} with any"],
  ["/api/network/approvals", "bare array without filters, {approvals, total, limit, offset} with any; ?id= answers {approval}, ?count=1 answers {counts}"],
  ["/api/machines", "bare array or {machines}"],
  ["/api/monitors", "bare array or {monitors}"],
  ["/api/task-results", "bare array or {results}"],
]);

function notes(call) {
  const out = [];
  const envelope = ENVELOPE_ON_QUERY.get(call.path);
  if (envelope && call.method === "GET") out.push(`Envelope on query: ${envelope}`);
  else if (/\|/.test(call.type) && /\[\]/.test(call.type)) out.push("Dual shape: bare array or envelope");
  if (/PlanResponse|PlanResult|ConvertResult|ApprovalView\b/.test(call.type) && call.method !== "GET") out.push("Plan filing answer");
  return out.join("; ");
}

// ---------------------------------------------------------------------------

function cell(text) {
  return String(text ?? "").replace(/\|/g, "\\|").replace(/\n/g, " ") || " ";
}

function main() {
  const files = goFiles();
  const routes = serverRoutes(files);
  const handlers = handlerIndex(files);
  const calls = consoleCalls();

  const rows = new Map();
  for (const call of calls) {
    const key = `${call.method} ${call.path}`;
    if (rows.has(key)) continue;
    rows.set(key, { ...call, source: `index.ts:${call.line}` });
  }
  const missingFromConsole = [];
  for (const named of designEndpoints()) {
    const key = `${named.method} ${named.path}`;
    if (rows.has(key)) continue;
    const sameRoute = [...rows.values()].some((row) => row.method === named.method && row.path.replace(/\{[^}]*\}/g, "{}") === named.path.replace(/\{[^}]*\}/g, "{}"));
    if (sameRoute) continue;
    missingFromConsole.push(key);
    rows.set(key, { method: named.method, path: named.path, type: "not called by the console", payload: "see the design", source: "design" });
  }

  const sorted = [...rows.values()].sort((a, b) => a.path.localeCompare(b.path) || a.method.localeCompare(b.method));
  const unmatched = [];
  const lines = [];
  lines.push("# API shapes");
  lines.push("");
  lines.push("Generated by `scripts/api-shapes.mjs` from `lattice-dashboard/src/lib/api/index.ts` and `lattice-server/internal/server`. Do not edit by hand; rerun the script after either side changes (design section 8.9).");
  lines.push("");
  lines.push("Columns: the method and path as the console calls them (`{id}` marks a path parameter); the query keys (GET) or body keys (other methods); the TypeScript response type the console reads; the Go handler; the scope its route wrapper requires (`signed in` is any credential, `public` none); and every scope string the handler body names, which includes per-node checks and alternatives, so read the handler before relying on one. Notes mark dual-shape lists, envelope-on-query endpoints and plan filing answers. Response types are defined in `lattice-dashboard/src/lib/api/types.ts` unless the name says otherwise.");
  lines.push("");
  lines.push("| Method | Path | Query or body | Response (TS) | Go handler | Route scope | Handler scopes | Notes |");
  lines.push("|---|---|---|---|---|---|---|---|");
  for (const row of sorted) {
    const route = routeFor(routes, row.path);
    const handler = route ? handlers.get(route.handler) : undefined;
    if (!route) unmatched.push(`${row.method} ${row.path}`);
    lines.push(
      `| ${row.method} | \`${cell(row.path)}\` | ${cell(row.payload ? `\`${row.payload}\`` : "")} | ${cell(row.type === "void" ? "none" : `\`${row.type}\``)} | ${cell(handler ? `\`${route.handler}\` ${handler.at}` : route ? route.at : "no route found")} | ${cell(route ? route.wrapper : "")} | ${cell(handler ? handler.scopes.join(", ") : "")} | ${cell(notes(row))} |`,
    );
  }
  lines.push("");
  lines.push("## Traps");
  lines.push("");
  lines.push("- `GET /api/tasks` returns a bare array without query parameters and `{tasks, total, limit, offset}` with any. Task `origin` is `approval`, `rerun` or `direct`; statuses include `pending`, `stalled` and `expired`, all derived by the server.");
  lines.push("- `GET /api/incidents` accepts `state` only as a comma list of `pending`, `open`, `acknowledged`, `resolved` and answers 400 \"unknown state\" for anything else. `active`, `snoozed` and `all` are console URL filter names, never API values.");
  lines.push("- `/api/audit` filters are `action`, `actor_id`, `at_from`, `at_to`, `correlation_id`, `decision`, `exclude_action`, `exclude_decision`, `node_id`, `scope`, `token_id`, `q`, `limit`, `offset`; there is no id filter.");
  lines.push("- `/api/network/approvals` list filters are `status`, `plugin`, `node_id`, `since`, plus `limit`, `offset`, `include_dismissed`, `count`, `include=plan`; there is no `until`.");
  lines.push("- Notify delivery filters are `channel_id`, `event_type`, `outcome`, `event_id`, `source`, `source_id`.");
  lines.push("- Plan endpoints answer in five shapes: `{approval, findings}` (SSH Guard, DNS and similar plans), a bare `ApprovalView` (agent update), `{approval}`, `BeaconPlanResponse {approval, plan, findings}`, and `GroupPolicyPlanResult {affected, conflicts, orphaned, selector_impacts}`. `POST /api/netpolicy/convert` returns `NetPolicyConvertResult {group_policy, approval|null}`.");
  lines.push("- `GET /api/sshguard/status` rows carry `stage`, a `posture` object, `revert_deadline` and `actionable_approval_id`; the read needs `sshguard:read` plus `network:plan` per node and skips the rest without a hidden count.");
  lines.push("- `GET /api/monitors/paths` sends `degraded_at` (possibly null) only from a server that judges degraded, and `beacon_replans` with the request that would replan each drifted node.");
  lines.push("");
  if (missingFromConsole.length) {
    lines.push("## Named by the design, not called by the console");
    lines.push("");
    lines.push("These rows come from the server alone; their response shapes are read from the Go handler.");
    lines.push("");
    for (const key of missingFromConsole) lines.push(`- \`${key}\``);
    lines.push("");
  }
  if (unmatched.length) {
    lines.push("## No server route found");
    lines.push("");
    for (const key of unmatched) lines.push(`- \`${key}\``);
    lines.push("");
  }
  writeFileSync(out, lines.join("\n"));
  console.log(`${sorted.length} endpoints, ${missingFromConsole.length} from the design only, ${unmatched.length} without a route -> ${relative(process.cwd(), out)}`);
}

main();
