// Two-space JSON, with each frame and each step on one line so that a diff
// of the vector file reads as a list of changed frames.
export const pretty = (value) => {
  const line = (v) => JSON.stringify(v);
  const out = ["{"];
  const keys = Object.keys(value);
  keys.forEach((key, index) => {
    const v = value[key];
    const comma = index < keys.length - 1 ? "," : "";
    if (key === "scenarios") {
      out.push(`  "scenarios": [`);
      v.forEach((scenario, at) => {
        out.push(`    {`);
        out.push(`      "name": ${line(scenario.name)},`);
        out.push(`      "why": ${line(scenario.why)},`);
        out.push(`      "steps": [`);
        scenario.steps.forEach((step, i) => out.push(`        ${line(step)}${i < scenario.steps.length - 1 ? "," : ""}`));
        out.push(`      ]`);
        out.push(`    }${at < v.length - 1 ? "," : ""}`);
      });
      out.push(`  ]${comma}`);
    } else if (Array.isArray(v) && v.length && typeof v[0] === "object") {
      out.push(`  ${line(key)}: [`);
      v.forEach((item, i) => out.push(`    ${line(item)}${i < v.length - 1 ? "," : ""}`));
      out.push(`  ]${comma}`);
    } else {
      out.push(`  ${line(key)}: ${line(v)}${comma}`);
    }
  });
  out.push("}");
  return out.join("\n");
};
