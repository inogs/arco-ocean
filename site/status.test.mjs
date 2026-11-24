// SPDX-FileCopyrightText: 2026 Stefano Campanella
// SPDX-License-Identifier: MIT
//
// node --test site/

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  assess,
  componentLabel,
  duration,
  flagsSummary,
  lagDays,
  resolutionLabel,
  runAgeDays,
  utc,
} from "./status.js";

const NOW = Date.parse("2026-11-24T12:30:00Z");

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
      { res: "0p25", state: "finished", latest_run: "2026-11-24", runs: 147, flags: {} },
      { res: "0p5", state: "downloading", latest_run: "2026-11-23", runs: 146, flags: {} },
      { res: "1p0", state: "pending", latest_run: "2026-11-23", runs: 146, flags: {} },
    ],
    ...fields,
  };
}

test("a running collection with a recent heartbeat is downloading", () => {
  const verdict = assess(heartbeat({}), NOW);
  assert.equal(verdict.status, "downloading");
  assert.match(verdict.detail, /up to 2026-11-24 \(now 0\.5°\)/);
});

test("a running collection silent for three beats is stale", () => {
  // 15 minutes is the floor (three beats of 300 s).
  assert.equal(assess(heartbeat({ updated_at: "2026-11-24T12:15:00Z" }), NOW).status, "downloading");
  const verdict = assess(heartbeat({ updated_at: "2026-11-24T12:14:00Z" }), NOW);
  assert.equal(verdict.status, "stale");
  assert.match(verdict.detail, /No heartbeat for 16 min/);
});

test("a longer heartbeat waits longer before it is stale", () => {
  const slow = heartbeat({ heartbeat_seconds: 900, updated_at: "2026-11-24T12:00:00Z" });
  assert.equal(assess(slow, NOW).status, "downloading");
  assert.equal(assess({ ...slow, updated_at: "2026-11-24T11:44:00Z" }, NOW).status, "stale");
});

test("a finished collection is finished until stale_after_hours have passed", () => {
  const done = heartbeat({
    state: "finished",
    ended_at: "2026-11-24T12:20:00Z",
    updated_at: "2026-11-24T12:20:00Z",
  });
  const verdict = assess(done, NOW);
  assert.equal(verdict.status, "finished");
  assert.match(verdict.detail, /Every run up to 2026-11-24 is stored/);
  const later = Date.parse("2026-11-25T18:21:00Z"); // 30 h 1 min after the end
  const stale = assess(done, later);
  assert.equal(stale.status, "stale");
  assert.match(stale.detail, /for 1 d 6 h:/);
  assert.equal(assess(done, Date.parse("2026-11-25T18:20:00Z")).status, "finished");
});

test("a finished collection storing no new runs is stale", () => {
  const behind = (latest) =>
    heartbeat({
      state: "finished",
      ended_at: "2026-11-24T12:20:00Z",
      resolutions: [
        { res: "0p25", state: "not_published", latest_run: latest, runs: 147, flags: {} },
        { res: "1p0", state: "finished", latest_run: "2026-11-24", runs: 147, flags: {} },
      ],
    });
  // Two days behind: runs younger than missing_after may wait for their sources.
  assert.equal(assess(behind("2026-11-22"), NOW).status, "finished");
  const verdict = assess(behind("2026-11-21"), NOW);
  assert.equal(verdict.status, "stale");
  assert.match(verdict.detail, /behind the newest asked for \(2026-11-24\): 0\.25° \(2026-11-21, 3 days\)\./);
  // A repository without runs (missing, or unreadable) is behind too.
  assert.match(assess(behind(null), NOW).detail, /: 0\.25° \(no run stored\)\./);
  // Without the newest run asked for, nothing to compare.
  assert.equal(assess({ ...behind(null), target_run: null }, NOW).status, "finished");
  assert.equal(lagDays("2026-11-21", "2026-11-24"), 3);
  assert.equal(lagDays("bad", "2026-11-24"), null);
});

test("a finished collection's detail is shown (a run not published yet)", () => {
  const done = heartbeat({
    state: "finished",
    ended_at: "2026-11-24T12:20:00Z",
    detail: "A source has not published the newest run yet (0p25).",
  });
  assert.equal(assess(done, NOW).detail, "A source has not published the newest run yet (0p25).");
});

test("an aborted collection stays aborted, however old", () => {
  const failed = heartbeat({ state: "aborted", detail: "The download failed at 1p0." });
  assert.deepEqual(assess(failed, NOW + 10 * 24 * 3600 * 1000), {
    status: "aborted",
    label: "Aborted",
    detail: "The download failed at 1p0.",
  });
});

test("an unreadable heartbeat is unknown", () => {
  assert.equal(assess(null, NOW).status, "unknown");
  assert.equal(assess(heartbeat({ schema: 2 }), NOW).status, "unknown");
  assert.equal(assess(heartbeat({ state: "sleeping" }), NOW).status, "unknown");
  // A running heartbeat without a readable time cannot be trusted: stale.
  assert.equal(assess(heartbeat({ updated_at: "never" }), NOW).status, "stale");
});

test("labels and durations", () => {
  assert.equal(duration(3 * 60 * 1000), "3 min");
  assert.equal(duration(125 * 60 * 1000), "2 h 5 min");
  assert.equal(duration(27 * 3600 * 1000), "1 d 3 h");
  assert.equal(duration(48 * 3600 * 1000), "2 d");
  assert.equal(utc("2026-11-24T12:00:03Z"), "2026-11-24 12:00 UTC");
  assert.equal(utc(null), "–");
  assert.equal(resolutionLabel("0p25"), "0.25°");
  assert.equal(resolutionLabel("1p0"), "1.0°");
  assert.equal(componentLabel("glofas_forecast"), "GloFAS");
  assert.equal(componentLabel("glo12_forecast"), "GLO12");
  assert.equal(componentLabel("ifs_forecast"), "IFS");
  assert.equal(
    flagsSummary({ ifs_forecast: 1, glofas_forecast: 1, glo12_forecast: 0.4 }),
    "IFS 100 %, GloFAS 100 %, GLO12 40 %",
  );
  assert.equal(flagsSummary({}), "–");
});

test("the newest run's age, in days", () => {
  assert.equal(runAgeDays("2026-11-24", NOW), 0);
  assert.equal(runAgeDays("2026-11-21", NOW), 3);
  assert.equal(runAgeDays(null, NOW), null);
});
