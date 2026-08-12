import { readFileSync } from "node:fs";

const mix = readFileSync(new URL("../mix.exs", import.meta.url), "utf8").replaceAll("\r\n", "\n");
const expectedTargets = [
  ["linux_x86_64", "linux", "x86_64"],
  ["linux_aarch64", "linux", "aarch64"],
  ["windows_x86_64", "windows", "x86_64"],
  ["macos_x86_64", "darwin", "x86_64"],
  ["macos_aarch64", "darwin", "aarch64"],
];

if (!mix.includes('PASEO_RELAY_STANDALONE_BUILD') || !mix.includes('[:assemble, &Burrito.wrap/1]')) {
  throw new Error("standalone mode must wrap the assembled release with Burrito");
}
if (!mix.includes('else: [:assemble]')) throw new Error("the default OTP release path must remain available");
if (!mix.includes('{:burrito, "== 1.6.0", runtime: false}')) {
  throw new Error("standalone releases must pin Burrito 1.6.0 as a build-only dependency");
}

for (const [name, os, cpu] of expectedTargets) {
  const target = `${name}: [os: :${os}, cpu: :${cpu}]`;
  if (!mix.includes(target)) throw new Error(`Missing standalone target: ${target}`);
}

const configuredTargetCount = mix
  .split("\n")
  .filter((line) => line.includes(": [os: :") && line.includes(", cpu: :")).length;
if (configuredTargetCount !== expectedTargets.length) {
  throw new Error(`Expected exactly ${expectedTargets.length} Burrito targets, found ${configuredTargetCount}`);
}

console.log(`Validated ${expectedTargets.length} standalone release targets and Burrito wrap step.`);
