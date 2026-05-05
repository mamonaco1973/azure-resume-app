/* ========================================================================== */
/* app.js                                                                      */
/* Dashboard controller. Subscribes to Entra auth state and drives the UI:   */
/* redirects to sign-in when signed out, loads the job list when signed in.  */
/* ========================================================================== */

import { createJob, listResumes }                   from "./api.js";
import { loadJobs, hasPendingJobs }                 from "./jobs.js";
import { bindResumeHandlers, openResumeManager }    from "./resumes.js";
import { onAuthChange, signIn, signOut }             from "./auth.js";

let lastSelectedResumeId = "";
let autoRefreshTimer     = null;
let countdownInterval    = null;

const AUTO_REFRESH_SECONDS = 5;

document.addEventListener("DOMContentLoaded", () => {
  bindUiHandlers();
  bindResumeHandlers();

  // Entra auth state is read synchronously from sessionStorage on each load
  onAuthChange(async (user) => {
    updateAuthButtons(!!user);
    if (user) {
      try {
        await refreshApp();
      } catch (error) {
        console.error("Failed to load dashboard:", error);
      }
    } else {
      showNotLoggedInMessage();
    }
  });
});

/* -------------------------------------------------------------------------- */
/* Function: bindUiHandlers                                                    */
/* Purpose: Attach all event listeners for the dashboard: modal open/close,  */
/*          source type toggle, form submit, and auth buttons.                */
/* -------------------------------------------------------------------------- */
function bindUiHandlers() {
  const newJobModal    = document.getElementById("new-job-modal");
  const resumeModal    = document.getElementById("resume-modal");

  const btnNewJob        = document.getElementById("btn-new-job");
  const btnManageResumes = document.getElementById("btn-manage-resumes");
  const cancelNewJob     = document.getElementById("cancel-new-job");
  const btnSignIn        = document.getElementById("btn-sign-in");
  const btnSignOut       = document.getElementById("btn-sign-out");
  const sourceType       = document.getElementById("source-type");
  const resumeSelect     = document.getElementById("resume-select");
  const newJobForm       = document.getElementById("new-job-form");

  // ---------------------------------------------------------------------------
  // Sign-in redirects to Entra hosted UI; sign-out clears token and redirects
  // ---------------------------------------------------------------------------

  btnSignIn?.addEventListener("click", () => signIn());

  btnSignOut?.addEventListener("click", async () => {
    await signOut();
  });

  // ---------------------------------------------------------------------------
  // Track last selected resume across modal open/close cycles
  // ---------------------------------------------------------------------------

  resumeSelect?.addEventListener("change", () => {
    lastSelectedResumeId = resumeSelect.value;
  });

  // ---------------------------------------------------------------------------
  // New Job modal
  // ---------------------------------------------------------------------------

  btnNewJob?.addEventListener("click", async () => {
    try {
      resumeModal?.classList.add("hidden");
      resetNewJobForm();
      await populateResumeSelect();
      updateSourceFields();
      newJobModal?.classList.remove("hidden");
      updateNewJobFormValidation();
    } catch (error) {
      window.alert(`Failed to load resumes: ${error.message}`);
    }
  });

  btnManageResumes?.addEventListener("click", async () => {
    newJobModal?.classList.add("hidden");
    await openResumeManager();
  });

  cancelNewJob?.addEventListener("click", () => {
    newJobModal?.classList.add("hidden");
  });

  // ---------------------------------------------------------------------------
  // Source type toggle and live validation
  // ---------------------------------------------------------------------------

  sourceType?.addEventListener("change", () => {
    updateSourceFields();
    updateNewJobFormValidation();
  });

  resumeSelect?.addEventListener("change", updateNewJobFormValidation);

  document.getElementById("job-url")
    ?.addEventListener("input", updateNewJobFormValidation);
  document.getElementById("job-description")
    ?.addEventListener("input", updateNewJobFormValidation);
  document.getElementById("linkedin-job-ids")
    ?.addEventListener("input", updateNewJobFormValidation);

  // ---------------------------------------------------------------------------
  // New Job form submit
  // ---------------------------------------------------------------------------

  newJobForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const validation = validateNewJobForm();
    clearNewJobFormErrors();
    if (!validation.isValid) {
      renderNewJobFormErrors(validation.errors);
      return;
    }
    await submitJobScoringRequest();
    newJobModal?.classList.add("hidden");
    resetNewJobForm();
    await refreshApp();
  });

  document.getElementById("btn-refresh")?.addEventListener("click", refreshApp);
}

/* ================================================================================
/* Source Type / Form Helpers
/* ================================================================================ */

function updateSourceFields() {
  const sourceType    = document.getElementById("source-type");
  const urlField      = document.getElementById("url-field");
  const textField     = document.getElementById("text-field");
  const linkedinField = document.getElementById("linkedin-field");
  if (!sourceType) return;
  urlField?.classList.add("hidden");
  textField?.classList.add("hidden");
  linkedinField?.classList.add("hidden");
  if (sourceType.value === "url")              urlField?.classList.remove("hidden");
  if (sourceType.value === "raw_text")         textField?.classList.remove("hidden");
  if (sourceType.value === "linkedin_job_id")  linkedinField?.classList.remove("hidden");
}

async function populateResumeSelect() {
  const resumeSelect = document.getElementById("resume-select");
  if (!resumeSelect) return;
  const resumes = await listResumes();
  resumeSelect.innerHTML = "";
  if (!Array.isArray(resumes) || resumes.length === 0) {
    const option = document.createElement("option");
    option.value = ""; option.textContent = "No resumes available";
    option.disabled = true; option.selected = true;
    resumeSelect.appendChild(option);
    return;
  }
  resumes.forEach((resume) => {
    const option = document.createElement("option");
    option.value       = resume.resume_id;
    option.textContent = resume.name || "Untitled Resume";
    resumeSelect.appendChild(option);
  });
  const hasSaved = resumes.some((r) => r.resume_id === lastSelectedResumeId);
  resumeSelect.value = hasSaved ? lastSelectedResumeId : resumes[0].resume_id;
  if (!hasSaved) lastSelectedResumeId = resumes[0].resume_id;
}

function resetNewJobForm() {
  document.getElementById("new-job-form")?.reset();
  document.getElementById("source-type").value = "url";
  document.getElementById("job-url").value = "";
  document.getElementById("job-description").value = "";
  document.getElementById("linkedin-job-ids").value = "";
  updateSourceFields();
}

/* ================================================================================
/* Validation
/* ================================================================================ */

function validateNewJobForm() {
  const errors       = {};
  const resumeId     = document.getElementById("resume-select")?.value.trim()         || "";
  const sourceType   = document.getElementById("source-type")?.value                  || "url";
  const jobUrl       = document.getElementById("job-url")?.value.trim()               || "";
  const jobDesc      = document.getElementById("job-description")?.value.trim()       || "";
  const linkedinRaw  = document.getElementById("linkedin-job-ids")?.value.trim()      || "";
  const resumeSelect = document.getElementById("resume-select");
  const hasResumes   = Array.from(resumeSelect?.options || []).some((o) => o.value.trim());

  if (!resumeId) {
    errors.resume = hasResumes
      ? "You must select a resume."
      : "Please add a resume with Manage Resumes.";
  }
  if (sourceType === "url") {
    if (!jobUrl)               errors.jobUrl = "Job URL is required.";
    else if (!isValidUrl(jobUrl)) errors.jobUrl = "URL is invalid. Enter a valid http or https URL.";
  }
  if (sourceType === "raw_text") {
    if (!jobDesc)              errors.jobDescription = "Job description is required.";
    else if (jobDesc.length < 100) errors.jobDescription = "Job description is too short.";
  }
  if (sourceType === "linkedin_job_id") {
    const ids = parseLinkedInJobIds(linkedinRaw);
    if (!ids.length)                    errors.linkedinJobIds = "Enter at least one LinkedIn job ID.";
    else if (!ids.every(isValidLinkedInJobId)) errors.linkedinJobIds = "Each LinkedIn Job ID must be numeric and 7 to 12 digits long.";
  }
  return { isValid: Object.keys(errors).length === 0, errors };
}

function parseLinkedInJobIds(value) {
  return value.split(/\n+/).map((s) => s.trim()).filter(Boolean);
}

function isValidLinkedInJobId(value) {
  return /^\d{7,12}$/.test(value);
}

function renderNewJobFormErrors(errors) {
  setFieldError("resume-error",            errors.resume);
  setFieldError("job-url-error",           errors.jobUrl);
  setFieldError("job-description-error",   errors.jobDescription);
  setFieldError("linkedin-job-ids-error",  errors.linkedinJobIds);
}

function clearNewJobFormErrors() {
  renderNewJobFormErrors({});
}

function setFieldError(elementId, message) {
  const el = document.getElementById(elementId);
  if (!el) return;
  if (message) {
    el.textContent = message;
    el.classList.remove("hidden");
  } else {
    el.textContent = "";
    el.classList.add("hidden");
  }
}

function updateNewJobFormValidation() {
  const validation = validateNewJobForm();
  renderNewJobFormErrors(validation.errors);
  const btn = document.getElementById("submit-new-job");
  if (btn) btn.disabled = !validation.isValid;
}

function isValidUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch { return false; }
}

/* ================================================================================
/* Job Submission
/* ================================================================================ */

async function submitJobScoringRequest() {
  const resumeId   = document.getElementById("resume-select")?.value.trim() || "";
  const sourceType = document.getElementById("source-type")?.value          || "url";

  if (sourceType === "url") {
    await createJob({
      resume_id:   resumeId,
      source_type: "url",
      job_url:     document.getElementById("job-url")?.value.trim() || "",
    });
    return;
  }

  if (sourceType === "raw_text") {
    await createJob({
      resume_id:       resumeId,
      source_type:     "raw_text",
      job_description: document.getElementById("job-description")?.value.trim() || "",
    });
    return;
  }

  if (sourceType === "linkedin_job_id") {
    const ids = (document.getElementById("linkedin-job-ids")?.value.trim() || "")
      .split("\n").map((id) => id.trim()).filter(Boolean);
    for (const id of ids) {
      await createJob({
        resume_id:   resumeId,
        source_type: "url",
        job_url:     `https://www.linkedin.com/jobs/view/${id}`,
      });
    }
  }
}

/* ================================================================================
/* Auto-Refresh
/* ================================================================================ */

/* -------------------------------------------------------------------------- */
/* Function: scheduleAutoRefresh                                               */
/* Purpose: If any job is still pending, schedule a countdown refresh.        */
/*          Resets the timer on each manual refresh so timers don't stack.    */
/* -------------------------------------------------------------------------- */
function scheduleAutoRefresh() {
  if (autoRefreshTimer   !== null) { clearTimeout(autoRefreshTimer);    autoRefreshTimer   = null; }
  if (countdownInterval  !== null) { clearInterval(countdownInterval);  countdownInterval  = null; }

  const indicator = document.getElementById("auto-refresh-indicator");
  const text      = document.getElementById("auto-refresh-text");
  const spinner   = indicator?.querySelector(".spinner");

  if (hasPendingJobs()) {
    spinner?.classList.remove("hidden");
    indicator?.classList.remove("hidden");
    let remaining = AUTO_REFRESH_SECONDS;
    if (text) text.textContent = `Auto-refreshing in ${remaining}s...`;
    countdownInterval = setInterval(() => {
      remaining -= 1;
      if (text) text.textContent = `Auto-refreshing in ${remaining}s...`;
    }, 1000);
    autoRefreshTimer = setTimeout(() => {
      clearInterval(countdownInterval);
      countdownInterval = null;
      autoRefreshTimer  = null;
      refreshApp();
    }, AUTO_REFRESH_SECONDS * 1000);
  } else {
    indicator?.classList.add("hidden");
  }
}

async function refreshApp() {
  if (countdownInterval !== null) { clearInterval(countdownInterval); countdownInterval = null; }
  const refreshButton = document.getElementById("btn-refresh");
  const table         = document.getElementById("jobs-table");
  try {
    if (refreshButton) refreshButton.disabled = true;
    table?.classList.add("loading");
    await loadJobs();
  } catch (error) {
    console.error("Failed to refresh dashboard:", error);
    window.alert(`Failed to refresh jobs: ${error.message}`);
  } finally {
    if (refreshButton) refreshButton.disabled = false;
    table?.classList.remove("loading");
    scheduleAutoRefresh();
  }
}

/* ================================================================================
/* Auth UI Helpers
/* ================================================================================ */

/* -------------------------------------------------------------------------- */
/* Function: updateAuthButtons                                                 */
/* Purpose: Toggle sign-in/sign-out visibility and enable action buttons      */
/*          based on the current auth state.                                  */
/* -------------------------------------------------------------------------- */
function updateAuthButtons(loggedIn) {
  document.getElementById("btn-sign-in")?.classList.toggle("hidden",  loggedIn);
  document.getElementById("btn-sign-out")?.classList.toggle("hidden", !loggedIn);
  for (const id of ["btn-refresh", "btn-new-job", "btn-manage-resumes"]) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (loggedIn) el.removeAttribute("disabled");
    else          el.setAttribute("disabled", "true");
  }
}

function showNotLoggedInMessage() {
  document.getElementById("jobs-table")?.classList.add("hidden");
  const emptyState = document.getElementById("empty-state");
  if (emptyState) {
    emptyState.classList.remove("hidden");
    emptyState.innerHTML = "<p>Please sign in to use the application.</p>";
  }
}
