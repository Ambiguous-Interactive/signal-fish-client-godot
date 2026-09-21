// Weekly web-export browser check: boots the exported demo in headless
// Chromium over local HTTPS and executes the browser-export checklist —
// engine boot, real wss:// dial with the browser-set Origin asserted
// server-side, Authenticate/Ping round-trips, and ws:// mixed-content
// refusal through the client predial check (loopback dials are exempt from
// browser mixed-content blocking, so the browser-level block only applies
// to production hosts). See docs/web-export.md and PLAN.md P4.
const { chromium } = require("playwright");
const { spawn } = require("node:child_process");
const path = require("node:path");

const REPO_ROOT = path.resolve(__dirname, "..");
const HTTPS_PORT = 8443;
const WSS_PORT = 8444;
const HOST = "127.0.0.1";
const BOOT_TIMEOUT_MS = 90_000;

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index !== -1 && process.argv[index + 1] !== undefined
    ? process.argv[index + 1]
    : fallback;
}

const webRoot = path.resolve(REPO_ROOT, arg("web-root", "build/web"));
const tlsKey = path.resolve(REPO_ROOT, arg("key", "build/smoke-certs/key.pem"));
const tlsCert = path.resolve(REPO_ROOT, arg("cert", "build/smoke-certs/cert.pem"));

class SmokeServer {
  constructor() {
    this.events = [];
    this.process = null;
    this.closePromise = null;
  }

  start() {
    this.events = [];
    this.closePromise = null;
    this.process = spawn(
      process.execPath,
      [
        path.join(REPO_ROOT, "scripts", "web_smoke_server.mjs"),
        "--web-root",
        webRoot,
        "--https-port",
        String(HTTPS_PORT),
        "--wss-port",
        String(WSS_PORT),
        "--key",
        tlsKey,
        "--cert",
        tlsCert,
      ],
      { cwd: REPO_ROOT, stdio: ["ignore", "pipe", "inherit"] },
    );
    let buffer = "";
    this.process.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      let newline = buffer.indexOf("\n");
      while (newline !== -1) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (line.startsWith("SMOKE ")) {
          this.events.push(JSON.parse(line.slice("SMOKE ".length)));
        }
        newline = buffer.indexOf("\n");
      }
    });
    return this.waitEvent("listening", (e) => e.role === "wss");
  }

  async stop() {
    if (!this.process) return;
    const child = this.process;
    this.process = null;
    this.closePromise = new Promise((resolve) => {
      child.once("close", resolve);
      child.kill("SIGTERM");
    });
    await this.closePromise;
  }

  waitEvent(event, predicate = () => true, timeoutMs = 30_000) {
    return new Promise((resolve, reject) => {
      const started = Date.now();
      const poll = () => {
        const found = this.events.find((e) => e.event === event && predicate(e));
        if (found) {
          resolve(found);
          return;
        }
        if (Date.now() - started > timeoutMs) {
          reject(new Error(`timed out waiting for ${event}; events: ${JSON.stringify(this.events)}`));
          return;
        }
        setTimeout(poll, 100);
      };
      poll();
    });
  }
}

async function waitForLog(page, needle, timeoutMs = BOOT_TIMEOUT_MS) {
  await page.waitForFunction(
    (probe) =>
      Array.isArray(window.__sfSmokeLogs) &&
      window.__sfSmokeLogs.some((line) => line.includes(probe)),
    needle,
    { timeout: timeoutMs, polling: 250 },
  );
}

async function collectSmokeLogs(page) {
  return page.evaluate(() => [...(window.__sfSmokeLogs ?? [])]);
}

function fail(message, logs) {
  console.error(`FAIL: ${message}`);
  if (logs) console.error(`demo log:\n${logs.join("\n")}`);
  process.exitCode = 1;
}

function demoUrl(searchParams) {
  const params = new URLSearchParams(searchParams);
  return `https://${HOST}:${HTTPS_PORT}/index.html?${params.toString()}`;
}

async function main() {
  const server = new SmokeServer();
  let browser;
  try {
    browser = await chromium.launch({ args: ["--no-sandbox"] });
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    await context.addInitScript(() => {
      window.__sfSmokeLogs = [];
      window.__sfSmokeLog = (line) => window.__sfSmokeLogs.push(String(line));
    });
    const page = await context.newPage();
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(String(error)));

    // Phase 1: engine boot over HTTPS + real wss:// dial with browser-set Origin.
    await server.start();
    const bootResponse = await page.goto(
      demoUrl({ sf_smoke_endpoint: `wss://${HOST}:${WSS_PORT}`, sf_smoke_app_id: "web-smoke" }),
      { waitUntil: "domcontentloaded", timeout: 30_000 },
    );
    if (!bootResponse || bootResponse.status() !== 200) {
      fail(`index.html did not load over HTTPS (status ${bootResponse && bootResponse.status()})`);
      return;
    }
    await waitForLog(page, "fill in endpoint + app id, then Connect");
    await waitForLog(page, "pong");
    const logs = await collectSmokeLogs(page);
    const expected = ["connect: OK", "connected", "authenticated as app 'web-smoke' (smoke)", "ping: OK", "pong"];
    const missing = expected.filter((line) => !logs.some((log) => log.includes(line)));
    if (missing.length > 0) {
      fail(`wss flow missing log lines: ${missing.join(" | ")}`, logs);
      return;
    }
    await server.waitEvent("ws_open", (e) => e.origin_ok === true);
    await server.waitEvent("message", (e) => e.type === "Authenticate");
    await server.waitEvent("pong_sent");

    // Phase 2: ws:// from the HTTPS page must be refused by the client
    // predial check, with the exact mixed-content message, before any dial.
    await server.stop();
    await server.start();
    await page.goto(
      demoUrl({ sf_smoke_endpoint: `ws://${HOST}:${WSS_PORT}`, sf_smoke_app_id: "web-smoke" }),
      { waitUntil: "domcontentloaded", timeout: 30_000 },
    );
    await waitForLog(page, "protocol error: ws:// is blocked from secure pages");
    await waitForLog(page, "connect: Invalid parameter");
    const insecureLogs = await collectSmokeLogs(page);
    if (insecureLogs.some((line) => line === "connected")) {
      fail("ws:// dial unexpectedly connected from a secure page", insecureLogs);
      return;
    }
    if (server.events.some((e) => e.event === "ws_open")) {
      fail("a ws:// dial reached the smoke server despite the predial refusal", insecureLogs);
      return;
    }
    if (pageErrors.length > 0) {
      fail(`page errors during smoke: ${pageErrors.join(" | ")}`, logs);
      return;
    }
    console.log("web-export browser check passed: HTTPS boot, wss+Origin, ws:// predial refusal");
  } catch (error) {
    fail(String(error && error.stack ? error.stack : error));
  } finally {
    await server.stop();
    if (browser) await browser.close();
  }
}

main();
