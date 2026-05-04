/* ========================================================================== */
/* jobs.js                                                                     */
/* Fetches the job list, renders the jobs table, and handles column sorting   */
/* and per-row deletion. Exported loadJobs() is the public entry point.       */
/* ========================================================================== */

import { deleteJob, listJobs } from "./api.js";

let jobs = [];
let currentSort = {
  field:     "created_at",
  direction: "desc"
};

// -----------------------------------------------------------------------------
// Public entry point
// -----------------------------------------------------------------------------

export async function loadJobs() {
  jobs = await listJobs();
  sortJobs();
  renderJobsTable();
  bindSortHandlers();
}

// Returns true if any job is still being processed, so the dashboard
// knows to keep polling.
export function hasPendingJobs() {
  return jobs.some(
    (job) => job.status === "submitted" || job.status === "Scoring"
  );
}

// -----------------------------------------------------------------------------
// Sorting
// -----------------------------------------------------------------------------

function bindSortHandlers() {
  const headers = document.querySelectorAll("th[data-sort]");
  headers.forEach((header) => {
    if (header.dataset.bound === "true") return;
    header.addEventListener("click", () => {
      const field = header.dataset.sort;
      if (currentSort.field === field) {
        currentSort.direction = currentSort.direction === "asc" ? "desc" : "asc";
      } else {
        currentSort.field     = field;
        currentSort.direction = "asc";
      }
      sortJobs();
      renderJobsTable();
    });
    header.dataset.bound = "true";
  });
}

/* -------------------------------------------------------------------------- */
/* Function: sortJobs                                                          */
/* Purpose: Sort the jobs array in place using currentSort field/direction.   */
/* -------------------------------------------------------------------------- */
function sortJobs() {
  const { field, direction } = currentSort;
  jobs.sort((a, b) => {
    const aVal = normalizeSortValue(a[field], field);
    const bVal = normalizeSortValue(b[field], field);
    if (aVal < bVal) return direction === "asc" ? -1 : 1;
    if (aVal > bVal) return direction === "asc" ?  1 : -1;
    return 0;
  });
}

/* -------------------------------------------------------------------------- */
/* Function: normalizeSortValue                                                */
/* Purpose: Coerce a field value into a type-appropriate form for comparison. */
/*          API returns timestamps in milliseconds, so new Date() is correct. */
/* -------------------------------------------------------------------------- */
function normalizeSortValue(value, field) {
  if (field === "score") {
    return value == null ? -1 : Number(value);
  }
  if (field === "created_at" || field === "updated_at") {
    return value ? new Date(value).getTime() : 0;
  }
  return (value || "").toString().toLowerCase();
}

// -----------------------------------------------------------------------------
// Rendering
// -----------------------------------------------------------------------------

function renderJobsTable() {
  const tbody      = document.getElementById("jobs-body");
  const emptyState = document.getElementById("empty-state");
  const table      = document.getElementById("jobs-table");

  tbody.innerHTML = "";

  if (!jobs.length) {
    table.classList.add("hidden");
    emptyState.classList.remove("hidden");
    return;
  }

  table.classList.remove("hidden");
  emptyState.classList.add("hidden");

  jobs.forEach((job) => {
    const row = document.createElement("tr");
    row.innerHTML = `
      <td>${escapeHtml(job.job_title || "—")}</td>
      <td>${escapeHtml(job.company  || "—")}</td>
      <td>${renderStatus(job.status)}</td>
      <td>${formatScore(job.score)}</td>
      <td>${formatDate(job.created_at)}</td>
      <td class="row-actions">
        <button type="button" class="open-job-btn"   data-job-id="${escapeHtml(job.job_id)}">Open</button>
        <button type="button" class="delete-job-btn" data-job-id="${escapeHtml(job.job_id)}">Delete</button>
      </td>
    `;
    tbody.appendChild(row);
  });

  bindOpenHandlers();
  bindDeleteHandlers();
}

function renderStatus(status) {
  const label = escapeHtml(status || "unknown");
  return `<span class="status-badge status-${label}">${label}</span>`;
}

function formatScore(score) {
  return score == null ? "—" : score;
}

function formatDate(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString();
}

// -----------------------------------------------------------------------------
// Open actions
// -----------------------------------------------------------------------------

function bindOpenHandlers() {
  document.querySelectorAll(".open-job-btn").forEach((button) => {
    if (button.dataset.bound === "true") return;
    button.addEventListener("click", () => {
      const jobId = button.dataset.jobId;
      if (jobId) window.open(`job.html?id=${encodeURIComponent(jobId)}`, jobId);
    });
    button.dataset.bound = "true";
  });
}

// -----------------------------------------------------------------------------
// Delete actions
// -----------------------------------------------------------------------------

function bindDeleteHandlers() {
  document.querySelectorAll(".delete-job-btn").forEach((button) => {
    if (button.dataset.bound === "true") return;
    button.addEventListener("click", async () => {
      const jobId = button.dataset.jobId;
      if (!jobId) return;
      if (!window.confirm("Delete this job and its stored data?")) return;

      const originalText = button.textContent;
      try {
        button.disabled    = true;
        button.textContent = "Deleting...";
        await deleteJob(jobId);
        jobs = jobs.filter((job) => job.job_id !== jobId);
        renderJobsTable();
      } catch (error) {
        window.alert(`Delete failed: ${error.message}`);
        button.disabled    = false;
        button.textContent = originalText;
      }
    });
    button.dataset.bound = "true";
  });
}

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
