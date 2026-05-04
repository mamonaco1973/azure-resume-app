/* ========================================================================== */
/* job.js                                                                      */
/* Job detail page: waits for Firebase auth, loads a single job by URL param, */
/* renders all fields, and handles inline notes saving.                        */
/* ========================================================================== */

import { getJob, updateJobNotes } from "./api.js";
import { waitForUser }            from "./auth.js";

document.addEventListener("DOMContentLoaded", async () => {
  const jobId = getJobIdFromUrl();

  if (!jobId) {
    renderError("Missing job ID.");
    return;
  }

  // Redirect unauthenticated visitors rather than letting the API return 401
  const user = await waitForUser();
  if (!user) {
    window.location.href = "index.html";
    return;
  }

  bindNotesHandler(jobId);

  try {
    const job = await getJob(jobId);
    renderJob(job);
  } catch (error) {
    renderError(`Failed to load job: ${error.message}`);
  }
});

/* -------------------------------------------------------------------------- */
/* Function: getJobIdFromUrl                                                   */
/* Purpose: Read the job ID from the "id" query parameter of the current URL. */
/* -------------------------------------------------------------------------- */
function getJobIdFromUrl() {
  const params = new URLSearchParams(window.location.search);
  return params.get("id")?.trim() || "";
}

/* -------------------------------------------------------------------------- */
/* Function: renderJob                                                         */
/* Purpose: Populate every field in the job detail view from the API response */
/*          object, then reveal the content panel and hide the loading state. */
/* -------------------------------------------------------------------------- */
function renderJob(job) {
  setText("job-title",          job.job_title      || "—");
  setText("job-company",        job.company        || "—");
  setText("job-status",         job.status         || "—");
  setText("job-status-message", job.status_message || "—");
  setText("job-score",          formatScore(job.score));
  setText("job-scored-at",      formatDate(job.created_at));
  setText("job-source-type",    job.source_type    || "—");

  renderJobUrl(job.job_url);
  renderTextBlock("job-analysis",    job.job_analysis);
  renderTextBlock("job-description", job.job_description);
  renderTextBlock("job-resume",      job.resume_snapshot);
  renderJobNotes(job.notes || "");

  document.getElementById("job-detail-loading")?.classList.add("hidden");
  document.getElementById("job-detail-content")?.classList.remove("hidden");
}

/* -------------------------------------------------------------------------- */
/* Function: renderJobUrl                                                      */
/* Purpose: Render the job URL as a safe anchor tag, or a dash if absent.     */
/* -------------------------------------------------------------------------- */
function renderJobUrl(value) {
  const element = document.getElementById("job-url");
  if (!element) return;
  if (!value) {
    element.textContent = "—";
    return;
  }
  element.innerHTML = `<a href="${escapeHtml(value)}" target="_blank" rel="noopener noreferrer">${escapeHtml(value)}</a>`;
}

/* -------------------------------------------------------------------------- */
/* Function: renderTextBlock                                                   */
/* Purpose: Set text content to the trimmed value, or a dash if empty.        */
/* -------------------------------------------------------------------------- */
function renderTextBlock(elementId, value) {
  const element = document.getElementById(elementId);
  if (!element) return;
  const text = String(value || "").trim();
  element.textContent = text || "—";
}

function renderJobNotes(value) {
  const element = document.getElementById("job-notes");
  if (element) element.value = value;
}

/* -------------------------------------------------------------------------- */
/* Function: bindNotesHandler                                                  */
/* Purpose: Wire the "Update Notes" button to save the textarea value via     */
/*          the API and display inline success or error feedback.             */
/* -------------------------------------------------------------------------- */
function bindNotesHandler(jobId) {
  const button   = document.getElementById("update-job-notes-btn");
  const textarea = document.getElementById("job-notes");
  if (!button || !textarea) return;

  button.addEventListener("click", async () => {
    clearNotesMessages();
    button.disabled    = true;
    button.textContent = "Updating...";
    try {
      await updateJobNotes(jobId, textarea.value);
      showNotesSuccess("Notes updated.");
    } catch (error) {
      showNotesError(`Failed to update notes: ${error.message}`);
    } finally {
      button.disabled    = false;
      button.textContent = "Update Notes";
    }
  });
}

function clearNotesMessages() {
  const err = document.getElementById("job-notes-error");
  const ok  = document.getElementById("job-notes-success");
  if (err) { err.textContent = "";  err.classList.add("hidden"); }
  if (ok)  { ok.textContent  = "";  ok.classList.add("hidden");  }
}

/* -------------------------------------------------------------------------- */
/* Function: showNotesError                                                    */
/* Purpose: Display an inline error below the notes field.                    */
/* -------------------------------------------------------------------------- */
function showNotesError(message) {
  const element = document.getElementById("job-notes-error");
  if (!element) { window.alert(message); return; }
  element.textContent = message;
  element.classList.remove("hidden");
}

/* -------------------------------------------------------------------------- */
/* Function: showNotesSuccess                                                  */
/* Purpose: Display an inline success message below the notes field.          */
/* -------------------------------------------------------------------------- */
function showNotesSuccess(message) {
  const element = document.getElementById("job-notes-success");
  if (!element) return;
  element.textContent = message;
  element.classList.remove("hidden");
}

function formatScore(score) {
  return score == null ? "—" : String(score);
}

function setText(elementId, value) {
  const element = document.getElementById(elementId);
  if (element) element.textContent = value;
}

/* -------------------------------------------------------------------------- */
/* Function: renderError                                                       */
/* Purpose: Show a page-level error and hide the loading state.               */
/* -------------------------------------------------------------------------- */
function renderError(message) {
  document.getElementById("job-detail-loading")?.classList.add("hidden");
  const errorElement = document.getElementById("job-detail-error");
  if (!errorElement) { window.alert(message); return; }
  errorElement.textContent = message;
  errorElement.classList.remove("hidden");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatDate(value) {
  if (!value) return "—";
  try {
    return new Date(value).toLocaleString();
  } catch { return value; }
}
