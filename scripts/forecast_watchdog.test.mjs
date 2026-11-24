// SPDX-FileCopyrightText: 2026 Stefano Campanella
// SPDX-License-Identifier: MIT
//
// node --test scripts/forecast_watchdog.test.mjs

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";

import { decide, plain, readHeartbeat, recorded } from "./forecast_watchdog.mjs";

const NOW = Date.parse("2026-11-24T12:30:00Z");
const CONTEXT = {
  now: NOW,
  statusUrl: "https://example.org/status/forecast.json",
  runUrl: "https://github.com/owner/repo/actions/runs/1",
  error: null,
};

function heartbeat(fields) {
  return {
    schema: 1,
    state: "running",
    detail: null,
    started_at: "2026-11-24T12:00:00Z",
    updated_at: "2026-11-24T12:28:00Z",
    ended_at: null,
    heartbeat_seconds: 300,
    stale_after_hours: 30,
    target_run: "2026-11-24",
    resolutions: [
      { res: "0p25", state: "finished", latest_run: "2026-11-24", runs: 147, error: null },
      { res: "0p5", state: "failed", latest_run: "2026-11-23", runs: 146, error: "a | b" },
    ],
    ...fields,
  };
}

const ABORTED = heartbeat({ state: "aborted", detail: "The download failed at 0p5." });

// The issue the watchdog would have opened for `beat`.
function issueFor(beat, state = "open") {
  const opened = decide(beat, null, CONTEXT);
  return { number: 7, state, body: opened.body };
}

const FINISHED = heartbeat({
  state: "finished",
  started_at: "2026-11-25T12:00:00Z",
  updated_at: "2026-11-25T12:20:00Z",
  ended_at: "2026-11-25T12:20:00Z",
});
const LATER = { ...CONTEXT, now: Date.parse("2026-11-25T12:30:00Z") };

test("a collection running or finished needs no issue", () => {
  assert.equal(decide(heartbeat({}), null, CONTEXT).action, "none");
  assert.equal(decide(FINISHED, null, LATER).action, "none");
});

test("an aborted collection opens an issue, with the resolutions and the incident", () => {
  const decision = decide(ABORTED, null, CONTEXT);
  assert.equal(decision.action, "open");
  assert.equal(decision.title, "Forecast collection: aborted");
  assert.match(decision.body, /^\*\*Aborted\.\*\* The download failed at 0p5\./);
  assert.match(decision.body, /\| 0\.5° \| Failed \| 2026-11-23 \| 146 \| a \\\| b \|/);
  assert.match(decision.body, /Heartbeat: https:\/\/example\.org\/status\/forecast\.json/);
  assert.deepEqual(recorded({ body: decision.body }), {
    status: "aborted",
    started_at: "2026-11-24T12:00:00Z",
  });
});

test("the same incident refreshes the issue's body, without a comment", () => {
  const issue = issueFor(ABORTED);
  // Hours later, the same collection still aborted.
  const decision = decide(ABORTED, issue, { ...CONTEXT, now: NOW + 6 * 3600e3 });
  assert.equal(decision.action, "refresh");
  assert.equal(decision.comment, undefined);
  assert.match(decision.body, /Checked at 2026-11-24 18:30 UTC/);
});

test("a silent collection is stale, and then its incident is updated", () => {
  const silent = heartbeat({ updated_at: "2026-11-24T12:00:00Z" });
  const opened = decide(silent, null, CONTEXT);
  assert.equal(opened.action, "open");
  assert.equal(opened.title, "Forecast collection: stale");
  // The same collection then reports its end, aborted: news.
  const update = decide(ABORTED, { number: 7, state: "open", body: opened.body }, CONTEXT);
  assert.equal(update.action, "update");
  assert.equal(update.title, "Forecast collection: aborted");
  assert.match(update.comment, /^Now \*\*aborted\*\*: The download failed at 0p5\./);
});

test("the incident lasts while the next collection downloads; one finished closes it", () => {
  const issue = issueFor(ABORTED);
  const next = heartbeat({ started_at: "2026-11-25T12:00:00Z", updated_at: "2026-11-25T12:28:00Z" });
  assert.equal(decide(next, issue, LATER).action, "none");
  // It aborts too: another incident, in the same issue.
  const again = { ...next, state: "aborted", detail: "The download failed at 0p5." };
  assert.equal(decide(again, issue, LATER).action, "update");
  const decision = decide(FINISHED, issue, LATER);
  assert.equal(decision.action, "close");
  assert.match(decision.comment, /^Recovered: \*\*Finished\.\*\* Every run up to 2026-11-24/);
});

test("an issue closed by hand acknowledges its incident, not the next", () => {
  const closed = issueFor(ABORTED, "closed");
  assert.equal(decide(ABORTED, closed, CONTEXT).action, "none");
  const next = { ...ABORTED, started_at: "2026-11-25T12:00:00Z" };
  assert.equal(decide(next, closed, LATER).action, "open");
  // A closed issue is never closed again.
  assert.equal(decide(FINISHED, closed, LATER).action, "none");
});

test("an issue without the marker is rewritten", () => {
  const edited = { number: 7, state: "open", body: "edited by hand" };
  assert.equal(recorded(edited), null);
  assert.equal(decide(ABORTED, edited, CONTEXT).action, "update");
});

test("an unreadable heartbeat is unknown, with the reason, unless an incident is open", () => {
  const context = { ...CONTEXT, error: "HTTP 404" };
  const decision = decide(null, null, context);
  assert.equal(decision.action, "open");
  assert.equal(decision.title, "Forecast collection: unknown");
  assert.match(decision.body, /Reading the heartbeat failed: HTTP 404/);
  assert.deepEqual(recorded({ body: decision.body }), { status: "unknown", started_at: null });
  // An aborted collection stays the incident while the heartbeat cannot be read.
  assert.equal(decide(null, issueFor(ABORTED), context).action, "none");
});

test("text from the heartbeat is inert in Markdown", () => {
  assert.equal(plain("@step #12 <!-- `x`\n| y & z"), "@⁠step #⁠12 &lt;!-- 'x' \\| y &amp; z");
  const loud = { ...ABORTED, detail: "failed: see #3, @someone <!--" };
  const decision = decide(loud, null, CONTEXT);
  assert.doesNotMatch(decision.body, /@someone|#3|<!-- [^f]/);
  assert.deepEqual(recorded({ body: decision.body }).status, "aborted");
  const odd = { ...ABORTED, started_at: "--> <b>" };
  assert.equal(recorded({ body: decide(odd, null, CONTEXT).body }).started_at, "--> <b>");
});

test("the heartbeat is read over HTTP, with attempts", async () => {
  let requests = 0;
  const server = createServer((request, response) => {
    requests += 1;
    if (request.url === "/missing") {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify(ABORTED));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const read = await readHeartbeat(`${base}/status.json`, { attempts: 3, waitMs: 0 });
    assert.equal(read.error, null);
    assert.equal(read.heartbeat.state, "aborted");
    requests = 0;
    const missing = await readHeartbeat(`${base}/missing`, { attempts: 3, waitMs: 0 });
    assert.deepEqual(missing, { heartbeat: null, error: "HTTP 404" });
    assert.equal(requests, 3);
  } finally {
    server.close();
  }
});
