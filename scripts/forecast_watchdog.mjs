// SPDX-FileCopyrightText: 2026 Stefano Campanella
// SPDX-License-Identifier: MIT
//
// The forecast collection's watchdog (.github/workflows/forecast-watchdog.yml): it reads the
// heartbeat as the web page does, judges it with the page's own site/status.js, and keeps one
// GitHub issue (label `forecast-alert`) open while the collection is stale, aborted or unknown.
// GitHub emails the issue's assignees and the repository's watchers: one email when an incident
// starts, one when it changes (another state, or another collection), one when the issue is
// closed, once a collection finishes. It runs outside the machine that collects, so a machine
// down is reported too. An issue closed by hand acknowledges its incident: it is not reopened.
//
// Environment: STATUS_URL (the heartbeat, https), GITHUB_TOKEN (issues: write),
// GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_SERVER_URL and GITHUB_RUN_ID (set by Actions),
// ALERT_ASSIGNEES (logins, comma-separated, optional), GITHUB_STEP_SUMMARY (optional).
//
// node scripts/forecast_watchdog.mjs; decide() is pure, tested by forecast_watchdog.test.mjs.

import { appendFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

import { assess, resolutionLabel, resolutionState, utc } from "../site/status.js";

export const LABEL = "forecast-alert";
export const ALERTING = new Set(["stale", "aborted", "unknown"]);
const MARKER = /<!-- forecast-watchdog (\{[^\n]*?\}) -->/;

// An incident is a state of a collection: the same state of the same collection is not news.
export function incident(verdict, heartbeat) {
  return { status: verdict.status, started_at: heartbeat?.started_at ?? null };
}

// The incident an issue was last written for, from the marker in its body.
export function recorded(issue) {
  const match = MARKER.exec(issue?.body ?? "");
  if (!match) return null;
  try {
    return JSON.parse(match[1]);
  } catch {
    return null;
  }
}

// Text from the heartbeat or an error, made inert in Markdown: no mention, no issue reference, no
// HTML, on one line.
export function plain(value) {
  return String(value ?? "–")
    .replaceAll(/\s+/g, " ")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("@", "@\u2060")
    .replaceAll("#", "#\u2060")
    .replaceAll("`", "'")
    .replaceAll("|", "\\|");
}

export function title(verdict) {
  return `Forecast collection: ${verdict.label.toLowerCase()}`;
}

// The issue's body: what the page shows, with the marker of the incident.
export function body(verdict, heartbeat, context) {
  const lines = [`**${verdict.label}.** ${plain(verdict.detail)}`];
  if (context.error) lines.push("", `Reading the heartbeat failed: ${plain(context.error)}`);
  if (heartbeat && typeof heartbeat === "object") {
    lines.push(
      "",
      `- Collection started: ${utc(heartbeat.started_at)}, last heartbeat: ` +
        `${utc(heartbeat.updated_at)}, ended: ${utc(heartbeat.ended_at)}`,
      `- Newest run asked for: ${plain(heartbeat.target_run)}`,
    );
    const resolutions = heartbeat.resolutions ?? [];
    if (resolutions.length > 0) {
      lines.push("", "| Resolution | State | Newest run | Runs | Error |", "|---|---|---|---|---|");
      for (const entry of resolutions) {
        lines.push(
          `| ${plain(resolutionLabel(entry.res))} | ${plain(resolutionState(entry.state))} ` +
            `| ${plain(entry.latest_run)} | ${plain(entry.runs)} | ${plain(entry.error)} |`,
        );
      }
    }
  }
  // JSON without "<" or ">", which could end the comment.
  const marker = JSON.stringify(incident(verdict, heartbeat))
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e");
  lines.push(
    "",
    `Heartbeat: ${context.statusUrl}`,
    `Checked at ${utc(new Date(context.now).toISOString())} by ${context.runUrl}`,
    "",
    "The watchdog closes this issue when a collection finishes. Closing it by hand acknowledges " +
      "this incident: another opens a new issue.",
    "",
    `<!-- forecast-watchdog ${marker} -->`,
  );
  return lines.join("\n");
}

// What to do, given the heartbeat now and the newest alert issue, open or closed (or null):
// {action: "none" | "open" | "refresh" | "update" | "close", ...}. "refresh" rewrites the body of
// the same incident (no email); an incident lasts until a collection finishes.
export function decide(heartbeat, issue, context) {
  const verdict = assess(heartbeat, context.now);
  const open = issue?.state === "open" ? issue : null;
  if (verdict.status === "finished") {
    if (!open) return { action: "none", verdict };
    return {
      action: "close",
      verdict,
      comment: `Recovered: **${verdict.label}.** ${plain(verdict.detail)}`,
    };
  }
  // Downloading: the incident, if any, lasts until the collection finishes.
  if (!ALERTING.has(verdict.status)) return { action: "none", verdict };
  // An unreadable heartbeat (S3 or the network, seen from GitHub) does not replace what is known.
  if (context.error && open) return { action: "none", verdict };
  const now = incident(verdict, heartbeat);
  const before = recorded(issue);
  const same = before?.status === now.status && before?.started_at === now.started_at;
  const text = { title: title(verdict), body: body(verdict, heartbeat, context) };
  if (!open) {
    // Closed by hand: the incident was acknowledged.
    if (issue && same) return { action: "none", verdict };
    return { action: "open", verdict, ...text };
  }
  if (same) return { action: "refresh", verdict, ...text };
  return {
    action: "update",
    verdict,
    ...text,
    comment: `Now **${verdict.label.toLowerCase()}**: ${plain(verdict.detail)}`,
  };
}

// The heartbeat, or null with the reason: attempts over three minutes, as a short outage of S3 or
// of the network is not news.
export async function readHeartbeat(url, { attempts = 4, waitMs = 60_000 } = {}) {
  let error = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(20_000) });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return { heartbeat: await response.json(), error: null };
    } catch (caught) {
      error = caught instanceof Error ? caught.message : String(caught);
    }
    if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, waitMs));
  }
  return { heartbeat: null, error };
}

async function github(method, path, payload) {
  const response = await fetch(`${process.env.GITHUB_API_URL ?? "https://api.github.com"}${path}`, {
    method,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "arco-ocean-forecast-watchdog",
    },
    body: payload === undefined ? undefined : JSON.stringify(payload),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) {
    const answer = (await response.text()).slice(0, 500);
    const error = new Error(`${method} ${path}: HTTP ${response.status}: ${answer}`);
    error.status = response.status;
    throw error;
  }
  return response.status === 204 ? null : response.json();
}

async function main() {
  const repo = process.env.GITHUB_REPOSITORY;
  const statusUrl = process.env.STATUS_URL;
  if (!repo || !statusUrl || !process.env.GITHUB_TOKEN) {
    throw new Error("STATUS_URL, GITHUB_TOKEN and GITHUB_REPOSITORY are needed");
  }
  const server = process.env.GITHUB_SERVER_URL ?? "https://github.com";
  const runUrl = `${server}/${repo}/actions/runs/${process.env.GITHUB_RUN_ID ?? ""}`;
  const { heartbeat, error } = await readHeartbeat(statusUrl);
  const issues = await github(
    "GET",
    `/repos/${repo}/issues?state=all&labels=${LABEL}&sort=created&direction=desc&per_page=10`,
  );
  // The newest, open or closed.
  const issue = issues.find((entry) => !entry.pull_request) ?? null;
  const context = { now: Date.now(), statusUrl, runUrl, error };
  const decision = decide(heartbeat, issue, context);

  if (decision.action === "open") {
    try {
      await github("POST", `/repos/${repo}/labels`, {
        name: LABEL,
        color: "d03b3b",
        description: "The forecast collection is stale, aborted or unknown (forecast watchdog)",
      });
    } catch (caught) {
      if (caught.status !== 422) throw caught; // 422: the label exists
    }
    const assignees = (process.env.ALERT_ASSIGNEES ?? "")
      .split(",")
      .map((login) => login.trim())
      .filter(Boolean);
    const fields = { title: decision.title, body: decision.body, labels: [LABEL] };
    let created;
    try {
      created = await github("POST", `/repos/${repo}/issues`, { ...fields, assignees });
    } catch (caught) {
      // A login that cannot be assigned refuses the whole issue: open it unassigned.
      if (caught.status !== 422 || assignees.length === 0) throw caught;
      console.log(`::warning::ALERT_ASSIGNEES refused (${caught.message}): issue unassigned`);
      created = await github("POST", `/repos/${repo}/issues`, fields);
    }
    decision.issue = created.number;
  } else if (decision.action === "refresh") {
    await github("PATCH", `/repos/${repo}/issues/${issue.number}`, { body: decision.body });
  } else if (decision.action === "update") {
    await github("PATCH", `/repos/${repo}/issues/${issue.number}`, {
      title: decision.title,
      body: decision.body,
    });
    await github("POST", `/repos/${repo}/issues/${issue.number}/comments`, {
      body: decision.comment,
    });
  } else if (decision.action === "close") {
    await github("POST", `/repos/${repo}/issues/${issue.number}/comments`, {
      body: decision.comment,
    });
    await github("PATCH", `/repos/${repo}/issues/${issue.number}`, {
      state: "closed",
      state_reason: "completed",
    });
  }

  const number = decision.issue ?? issue?.number;
  const summary =
    `Forecast collection: **${decision.verdict.label}**. ${decision.verdict.detail}\n\n` +
    `Alert issue: ${decision.action}${number ? ` (#${number})` : ""}.\n`;
  console.log(summary);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  await main();
}
