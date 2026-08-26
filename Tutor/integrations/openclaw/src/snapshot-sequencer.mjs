import {randomUUID} from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const FILE = "gateway-snapshot-sequence.json";

/// Persistent single-writer source identity for Gateway-to-Engine snapshots.
/// Gateway restart retains epoch and never resets sequence ordering.
export class GatewaySnapshotSequencer {
  constructor(stateDirectory) {
    this.file = path.join(stateDirectory, FILE);
    this.state = null;
    this.loading = null;
    this.tail = Promise.resolve();
  }

  async next() {
    const previous = this.tail;
    let release;
    this.tail = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      await this.load();
      if (this.state.sequence >= Number.MAX_SAFE_INTEGER) throw new Error("Gateway snapshot sequence exhausted");
      this.state.sequence += 1;
      await this.persist();
      return {sourceEpoch: this.state.epoch, sourceSequence: this.state.sequence};
    } finally { release(); }
  }

  async load() {
    if (this.state) return;
    if (!this.loading) {
      this.loading = (async () => {
        await fs.mkdir(path.dirname(this.file), {recursive: true, mode: 0o700});
        let candidate = null;
        try { candidate = JSON.parse(await fs.readFile(this.file, "utf8")); } catch (error) {
          if (error?.code !== "ENOENT") throw new Error("Gateway snapshot state is unreadable");
        }
        if (candidate && candidate.format === "calla-gateway-snapshot-sequence" && candidate.format_version === 1 &&
            typeof candidate.epoch === "string" && /^[A-Za-z0-9._-]{1,160}$/.test(candidate.epoch) &&
            Number.isSafeInteger(candidate.sequence) && candidate.sequence >= 0) {
          this.state = {epoch: candidate.epoch, sequence: candidate.sequence};
          return;
        }
        this.state = {epoch: `gateway-${randomUUID()}`, sequence: 0};
        await this.persist();
      })();
    }
    await this.loading;
  }

  async persist() {
    const temporary = `${this.file}.${randomUUID()}.tmp`;
    const data = JSON.stringify({format: "calla-gateway-snapshot-sequence", format_version: 1,
      epoch: this.state.epoch, sequence: this.state.sequence});
    await fs.writeFile(temporary, data, {mode: 0o600});
    await fs.rename(temporary, this.file);
    await fs.chmod(this.file, 0o600);
  }
}
