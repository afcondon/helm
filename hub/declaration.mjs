// Writes the two frame tables into conformance/HELM-HUB.md from the
// descriptions in test/Hub/Protocol.purs (`write`), or fails if the
// document's tables are not what the descriptions give (`check`).
//
// Run through `make vectors` and `make check-vectors`, after `spago build`.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const generated = await import(here("../output/Hub.Generate/index.js"));
const file = here("../conformance/HELM-HUB.md");

const splice = (text, marker, table) => {
  const open = `<!-- generated:${marker} -->`;
  const close = `<!-- /generated:${marker} -->`;
  const from = text.indexOf(open);
  const to = text.indexOf(close);
  if (from < 0 || to < from) throw new Error(`conformance/HELM-HUB.md has no ${marker} markers`);
  return text.slice(0, from + open.length) + "\n" + table + "\n" + text.slice(to);
};

const before = readFileSync(file, "utf8");
const after = splice(splice(before, "app", generated.appTable), "hub", generated.hubTable);

if (process.argv[2] === "write") {
  writeFileSync(file, after);
} else if (before !== after) {
  console.log("FAIL  conformance/HELM-HUB.md's tables are not what the descriptions give; run `make vectors`");
  process.exit(1);
} else {
  console.log("declaration: the tables are current");
}
