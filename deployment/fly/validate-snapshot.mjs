const maximumInputBytes = 16 * 1024;
let input = "";

for await (const chunk of process.stdin) {
  input += chunk;

  if (Buffer.byteLength(input) > maximumInputBytes) {
    console.error(`Fly diagnostic snapshot exceeded ${maximumInputBytes} bytes`);
    process.exit(1);
  }
}

const snapshots = input
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean)
  .flatMap((line) => {
    try {
      const value = JSON.parse(line);
      return value && typeof value === "object" && !Array.isArray(value) ? [value] : [];
    } catch {
      return [];
    }
  });

if (snapshots.length !== 1) {
  console.error(`Fly diagnostic RPC produced ${snapshots.length} JSON snapshot lines; expected 1`);
  process.exit(1);
}

const snapshot = snapshots[0];
const failures = [];
const check = (name, expected, actual, valid) => {
  if (!valid) failures.push(`${name} expected ${expected}, actual ${JSON.stringify(actual)}`);
};

check("schema", "1", snapshot.schema, snapshot.schema === 1);
check("machine_id", '"ci-machine"', snapshot.machine_id, snapshot.machine_id === "ci-machine");
check("private_ip", '"::1"', snapshot.private_ip, snapshot.private_ip === "::1");
check("release_node", '"paseo_relay@::1"', snapshot.release_node, snapshot.release_node === "paseo_relay@::1");
check("release_os_pid", "decimal OS pid", snapshot.release_os_pid, /^\d+$/.test(snapshot.release_os_pid));
check("owners.ci-unowned", '"unowned"', snapshot.owners?.["ci-unowned"], snapshot.owners?.["ci-unowned"] === "unowned");
check("connection_ceiling", "20000", snapshot.connection_ceiling, snapshot.connection_ceiling === 20000);
check("capacity_mutation_timeout_ms", "5000", snapshot.capacity_mutation_timeout_ms, snapshot.capacity_mutation_timeout_ms === 5000);
check("capacity_pid", '"#PID<n.n.n>"', snapshot.capacity_pid, /^#PID<\d+\.\d+\.\d+>$/.test(snapshot.capacity_pid));

if (failures.length > 0) {
  console.error(`Fly diagnostic snapshot invalid: ${failures.join("; ")}`);
  process.exit(1);
}
