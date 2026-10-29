// Regenerates the audit export goldens by running the console's own export
// code (lattice-dashboard/src/views/operations/AuditView.vue: csvCell,
// exportCsv, exportNdjson, offBoxAnchorRecord) over audit-export-events.json.
//
//   node --experimental-strip-types audit-export-generate.mjs <path to AuditView.vue>
//
// The functions are cut out of the .vue file verbatim, so the goldens follow
// the console rather than a re-statement of it.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const view = readFileSync(process.argv[2], "utf8");

function cut(start, end) {
  const from = view.indexOf(start);
  const to = view.indexOf(end, from);
  if (from < 0 || to < 0) throw new Error(`not found: ${start}`);
  return view.slice(from, to + end.length);
}

const csvCell = cut("function csvCell(", "\n}\n");
const exportCsv = cut("function exportCsv(", "\n}\n");
const exportNdjson = cut("function exportNdjson(", "\n}\n");
const anchor = cut("const offBoxAnchorRecord = computed(", "\n});\n");

const module = `
let files = {};
const events = { value: [] as any[] };
const verifyResult = { value: undefined as any };
const lastVerify = { value: null as any };
const toast = { success: () => {}, info: () => {} };
const t = (k: string) => k;
function computed<T>(f: () => T) { return { get value() { return f(); } }; }
function downloadFile(name: string, content: string) { files[name] = content; }
${csvCell}
${exportCsv}
${exportNdjson}
${anchor}
export function run(list: any[], verify: any, at: string) {
  files = {};
  events.value = list;
  exportCsv();
  exportNdjson();
  verifyResult.value = verify;
  lastVerify.value = { at };
  return { csv: files["lattice-audit.csv"], ndjson: files["lattice-audit.ndjson"], head: offBoxAnchorRecord.value + "\\n" };
}
`;
const dir = mkdtempSync(join(tmpdir(), "audit-golden-"));
const file = join(dir, "export.ts");
writeFileSync(file, module);
const { run } = await import(file);

const events = JSON.parse(readFileSync(join(here, "audit-export-events.json"), "utf8")).events;
const verify = { enabled: true, ok: true, count: 5760, head: "9f2c".repeat(16), anchored: true, anchor_count: 5760, anchor_head: "9f2c".repeat(16), anchor_pending: { count: 5761, head: "ab01".repeat(16) } };
const out = run(events, verify, "2026-10-28T12:00:00.000Z");
writeFileSync(join(here, "audit-export-golden.csv"), out.csv);
writeFileSync(join(here, "audit-export-golden.ndjson"), out.ndjson);
writeFileSync(join(here, "audit-export-golden-head.json"), out.head);
console.log("wrote audit-export-golden.csv, .ndjson and -head.json");
