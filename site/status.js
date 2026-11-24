// SPDX-FileCopyrightText: 2026 Stefano Campanella
// SPDX-License-Identifier: MIT
//
// The state of the forecast collection, from its heartbeat (scripts/forecast_status.py writes
// it; its docstring describes the document). Pure functions, tested by status.test.mjs.

export const DEFAULT_STATUS_URL =
  "https://ogs-arco-ocean.s3.eu-south-1.amazonaws.com/status/forecast.json";

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

// A running collection is stale when its heartbeat has been silent for three beats (at least
// 15 minutes); a finished one when the next has not finished within `stale_after_hours`.
const MISSED_BEATS = 3;
const MIN_SILENCE = 15 * MINUTE;
// A finished collection is stale too when a resolution falls behind (`behind`), by more than the
// recipes' `missing_after`, which the heartbeat publishes (two days if it does not).
const DEFAULT_MISSING_AFTER_DAYS = 2;

// "3 min", "2 h 5 min", "1 d 3 h".
export function duration(ms) {
  const minutes = Math.max(0, Math.floor(ms / MINUTE));
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 ? `${hours} h ${minutes % 60} min` : `${hours} h`;
  const days = Math.floor(hours / 24);
  return hours % 24 ? `${days} d ${hours % 24} h` : `${days} d`;
}

// "2026-11-24 12:00 UTC".
export function utc(iso) {
  if (!iso) return "–";
  const time = new Date(iso);
  if (Number.isNaN(time.getTime())) return "–";
  return `${time.toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

const RESOLUTION_STATES = {
  pending: "Waiting its turn",
  downloading: "Downloading",
  finished: "Finished",
  not_published: "Newest run not published yet",
  failed: "Failed",
};

export function resolutionState(state) {
  return RESOLUTION_STATES[state] ?? "Unknown";
}

// "0p25" -> "0.25°".
export function resolutionLabel(res) {
  return `${String(res).replace("p", ".")}°`;
}

// Flag variables name their component: "glo12_forecast" -> "GLO12", "glofas_forecast" ->
// "GloFAS", "ifs_forecast" -> "IFS".
const COMPONENTS = { glofas: "GloFAS" };

export function componentLabel(flag) {
  const name = String(flag).replace(/_forecast$/, "");
  return COMPONENTS[name] ?? name.toUpperCase();
}

// "IFS 100 %, GloFAS 100 %, GLO12 0 %": the share of the newest run's lead times that are the
// run's own forecast, per component.
export function flagsSummary(flags) {
  const entries = Object.entries(flags ?? {});
  if (entries.length === 0) return "–";
  return entries
    .map(([flag, share]) => `${componentLabel(flag)} ${Math.round(Number(share) * 100)} %`)
    .join(", ");
}

// The collection's state as the page shows it: downloading, finished, stale or aborted
// (unknown if the heartbeat cannot be read), with a sentence.
export function assess(heartbeat, now = Date.now()) {
  if (!heartbeat || typeof heartbeat !== "object") {
    return { status: "unknown", label: "Unknown", detail: "The heartbeat could not be read." };
  }
  if (heartbeat.schema !== 1) {
    return {
      status: "unknown",
      label: "Unknown",
      detail: `The heartbeat has an unknown format (schema ${heartbeat.schema}).`,
    };
  }
  const updated = Date.parse(heartbeat.updated_at);
  const beat = (Number(heartbeat.heartbeat_seconds) || 300) * 1000;
  const staleAfter = (Number(heartbeat.stale_after_hours) || 30) * HOUR;
  if (heartbeat.state === "running") {
    const silence = now - updated;
    if (!(silence <= Math.max(MISSED_BEATS * beat, MIN_SILENCE))) {
      return {
        status: "stale",
        label: "Stale",
        detail:
          `No heartbeat for ${duration(silence)}: the collection stopped without reporting ` +
          "(the machine down or the process killed). The next collection resumes it.",
      };
    }
    const current = (heartbeat.resolutions ?? []).find((r) => r.state === "downloading");
    const where = current ? ` (now ${resolutionLabel(current.res)})` : "";
    return {
      status: "downloading",
      label: "Downloading",
      detail: `Collecting the runs up to ${heartbeat.target_run}${where}.`,
    };
  }
  if (heartbeat.state === "aborted") {
    return {
      status: "aborted",
      label: "Aborted",
      detail: heartbeat.detail ?? "The collection failed: the next collection resumes it.",
    };
  }
  if (heartbeat.state === "finished") {
    const ended = Date.parse(heartbeat.ended_at ?? heartbeat.updated_at);
    if (!(now - ended <= staleAfter)) {
      return {
        status: "stale",
        label: "Stale",
        detail: `No collection has finished for ${duration(now - ended)}: one runs every day.`,
      };
    }
    const reasons = behind(heartbeat, now);
    if (reasons.length > 0) {
      return {
        status: "stale",
        label: "Stale",
        detail:
          `The collection finished, but ${reasons.join("; ")}: a source may have stopped ` +
          "publishing (the flags tell which), or the runs are not stored.",
      };
    }
    return {
      status: "finished",
      label: "Finished",
      detail: heartbeat.detail ?? `Every run up to ${heartbeat.target_run} is stored.`,
    };
  }
  return {
    status: "unknown",
    label: "Unknown",
    detail: `The heartbeat has an unknown state (${heartbeat.state}).`,
  };
}

// "YYYY-MM-DD" as the time of its midnight UTC, or null.
function day(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const time = Date.parse(`${value}T00:00:00Z`);
  return Number.isNaN(time) ? null : time;
}

// How many days the newest stored run is before the newest asked for (null if either is missing).
export function lagDays(latestRun, targetRun) {
  const run = day(latestRun);
  const target = day(targetRun);
  if (run === null || target === null) return null;
  return Math.round((target - run) / DAY);
}

// Why the resolutions of a finished collection are behind, if they are: a newest stored run older
// than the recipes' `missing_after` (runs that old are stored even without a source, flagged), or
// a resolution waiting for its sources for longer than that (a source that stopped publishing
// keeps it waiting every day, while its older runs are stored without it).
export function behind(heartbeat, now = Date.now()) {
  const limit = Number(heartbeat.missing_after_days) || DEFAULT_MISSING_AFTER_DAYS;
  const target = day(heartbeat.target_run);
  const reasons = [];
  for (const entry of heartbeat.resolutions ?? []) {
    const label = resolutionLabel(entry.res);
    if (target !== null) {
      const lag = lagDays(entry.latest_run, heartbeat.target_run);
      if (lag === null) {
        reasons.push(`${label} has no run stored`);
        continue;
      }
      if (lag > limit) {
        reasons.push(`${label}'s newest run is ${entry.latest_run}, ${lag} days before the newest`);
        continue;
      }
    }
    const since = Date.parse(entry.waiting_since ?? "");
    if (!Number.isNaN(since) && now - since > limit * DAY) {
      reasons.push(`${label} has waited for a source for ${duration(now - since)}`);
    }
  }
  return reasons;
}

// How old the newest stored run is, in whole days, at `now` (UTC dates).
export function runAgeDays(latestRun, now = Date.now()) {
  const run = day(latestRun);
  if (run === null) return null;
  const today = day(new Date(now).toISOString().slice(0, 10));
  return Math.round((today - run) / DAY);
}
