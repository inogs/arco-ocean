// SPDX-FileCopyrightText: 2026 Stefano Campanella
// SPDX-License-Identifier: MIT
//
// The forecast dashboard: reads the heartbeat every minute and shows the collection's state.
// `?status=URL` reads another heartbeat (a test copy, say).

import {
  DEFAULT_STATUS_URL,
  assess,
  duration,
  flagsSummary,
  resolutionLabel,
  resolutionState,
  runAgeDays,
  utc,
} from "./status.js";

const REFRESH_MS = 60 * 1000;
const ICONS = { downloading: "⟳", finished: "✓", stale: "!", aborted: "✕", unknown: "?" };

function statusUrl() {
  const given = new URLSearchParams(window.location.search).get("status");
  return given || DEFAULT_STATUS_URL;
}

async function fetchHeartbeat(url) {
  try {
    const answer = await fetch(url, { cache: "no-store" });
    if (!answer.ok) return null;
    return await answer.json();
  } catch {
    return null;
  }
}

function cell(row, text) {
  const td = document.createElement("td");
  td.textContent = text;
  row.append(td);
  return td;
}

function render(heartbeat, now) {
  const verdict = assess(heartbeat, now);
  const card = document.getElementById("status-card");
  card.dataset.status = verdict.status;
  document.getElementById("status-icon").textContent = ICONS[verdict.status];
  document.getElementById("status-label").textContent = verdict.label;
  document.getElementById("status-detail").textContent = verdict.detail;

  const ok = heartbeat && heartbeat.schema === 1;
  const updated = ok ? Date.parse(heartbeat.updated_at) : NaN;
  document.getElementById("status-started").textContent = ok ? utc(heartbeat.started_at) : "–";
  document.getElementById("status-beat").textContent = Number.isNaN(updated)
    ? "–"
    : `${utc(heartbeat.updated_at)} (${duration(now - updated)} ago)`;
  document.getElementById("status-ended").textContent =
    ok && heartbeat.ended_at ? utc(heartbeat.ended_at) : "–";
  document.getElementById("status-target").textContent = ok ? heartbeat.target_run : "–";

  const body = document.getElementById("status-resolutions");
  body.replaceChildren();
  for (const entry of ok ? (heartbeat.resolutions ?? []) : []) {
    const row = document.createElement("tr");
    cell(row, resolutionLabel(entry.res));
    cell(row, resolutionState(entry.state)).dataset.state = entry.state;
    const age = runAgeDays(entry.latest_run, now);
    const ageText = age === null ? "" : age === 0 ? " (today)" : ` (${age} d ago)`;
    cell(row, entry.latest_run ? `${entry.latest_run}${ageText}` : "–");
    cell(row, entry.runs ?? "–");
    cell(row, entry.error ?? flagsSummary(entry.flags));
    body.append(row);
  }
  document.getElementById("status-checked").textContent = utc(new Date(now).toISOString());
}

async function refresh() {
  render(await fetchHeartbeat(statusUrl()), Date.now());
}

refresh();
setInterval(refresh, REFRESH_MS);
