import net from "node:net";
import os from "node:os";
import path from "node:path";

import {validateNodeEnvelope} from "./protocol.mjs";

const MAX_RESPONSE_BYTES = Math.floor(1.5 * 1024 * 1024);

export class TutorHostUnavailableError extends Error {
  constructor(message, cause) {
    super(message, {cause});
    this.name = "TutorHostUnavailableError";
  }
}

export function defaultTutorSocketPath() {
  return path.join(os.homedir(), "Library", "Application Support", "boringNotch", "Calla", "tutor-host.sock");
}

export function defaultEngineIngressPath() {
  return path.join(os.homedir(), "Library", "Application Support", "boringNotch", "Calla", "engine-ingress.sock");
}

export async function invokeTutorHost(envelope, options = {}) {
  validateNodeEnvelope(envelope);
  return await invokeLocalEndpoint(envelope, {
    socketPath: options.socketPath || defaultTutorSocketPath(),
    timeoutMs: options.timeoutMs,
    endpointName: "TutorHost",
  });
}

export async function invokeTutorEngine(envelope, options = {}) {
  const allowed = new Set(["session_start", "catalogue", "course_status", "course_runtime", "gateway_health"]);
  validateNodeEnvelope(envelope);
  if (!allowed.has(envelope.operation)) {
    return {ok: false, code: "OPERATION_NOT_AVAILABLE_IN_ENGINE_MODE", message: "Operation unavailable in Boring Engine mode."};
  }
  if (typeof options.capabilityToken !== "string" || !/^[a-z0-9-]{36}$/i.test(options.capabilityToken)) {
    throw new TypeError("Boring Engine capability token is unavailable");
  }
  return await invokeLocalEndpoint({...envelope, capability_token: options.capabilityToken}, {
    socketPath: options.socketPath || defaultEngineIngressPath(),
    timeoutMs: options.timeoutMs,
    endpointName: "Boring Engine ingress",
  });
}

async function invokeLocalEndpoint(envelope, options) {
  const socketPath = options.socketPath;
  const timeoutMs = options.timeoutMs ?? 10_000;

  return await new Promise((resolve, reject) => {
    const client = net.createConnection({path: socketPath});
    let settled = false;
    let buffer = Buffer.alloc(0);

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      client.destroy();
      if (error) reject(error);
      else resolve(value);
    };

    const timer = setTimeout(() => finish(new Error(`${options.endpointName} local IPC request timed out`)), timeoutMs);
    timer.unref?.();

    client.once("connect", () => {
      client.write(`${JSON.stringify(envelope)}\n`);
    });
    client.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_RESPONSE_BYTES) {
        finish(new Error(`${options.endpointName} local IPC response exceeded 1.5 MiB`));
        return;
      }
      const newline = buffer.indexOf(0x0a);
      if (newline < 0) return;
      const trailing = buffer.subarray(newline + 1);
      if (trailing.some((byte) => byte > 0x20)) {
        finish(new Error(`${options.endpointName} returned multiple or trailing payloads`));
        return;
      }
      try {
        finish(null, JSON.parse(buffer.subarray(0, newline).toString("utf8")));
      } catch (error) {
        finish(new Error(`${options.endpointName} returned invalid JSON: ${error.message}`));
      }
    });
    client.once("error", (error) => finish(error));
    client.once("end", () => {
      if (!settled) finish(new Error(`${options.endpointName} closed local IPC before returning a response`));
    });
  });
}

/**
 * The node transport hands the handler a JSON string and expects one back.
 * Returning the parsed object instead is silently lossy: the invoke result
 * comes back `{ok: true, payloadJSON: null}` and the Mac's entire response —
 * snapshot, capture, error code — never reaches the Gateway.
 */
export async function handleTutorNodeHostCommand(rawParams, options = {}) {
  try {
    let envelope = rawParams;
    if (typeof rawParams === "string") {
      envelope = JSON.parse(rawParams);
    }
    const response = options.runtimeMode === "engine"
      ? await invokeTutorEngine(envelope, options)
      : await invokeTutorHost(envelope, options);
    return JSON.stringify(response);
  } catch (error) {
    if (error && ["ENOENT", "ECONNREFUSED", "EPIPE"].includes(error.code)) {
      return JSON.stringify({
        ok: false,
        code: "TUTOR_HOST_UNAVAILABLE",
        message: options.runtimeMode === "engine"
          ? "Boring Engine ingress is not running or is not accepting local requests."
          : "Calla TutorHost is not running or is not accepting local requests.",
      });
    }
    throw error;
  }
}
