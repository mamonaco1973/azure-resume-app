/* ========================================================================== */
/* app.js                                                                      */
/* Dashboard controller. Subscribes to Firebase auth state and drives the UI: */
/* shows the auth modal when signed out, loads the job list when signed in.   */
/* ========================================================================== */

import { createJob, listResumes }                   from "./api.js";
import { loadJobs, hasPendingJobs }                 from "./jobs.js";
import { bindResumeHandlers, openResumeManager }    from "./resumes.js";
import { onAuthChange, signIn, signUp, signOut }    from "./auth.js";

let lastSelectedResumeId = "";
let autoRefreshTimer     = null;
let countdownInterval    = null;
let authMode             = "signin";  // "signin" | "signup"

const AUTO_REFRESH_SECONDS = 5;

document.addEventListener("DOMContentLoaded", () => {
  bindUiHandlers();
  bindResumeHandlers();

  // Firebase auth state drives the entire UI — no manual token checks needed
  onAuthChange(async (user) => {
    updateAuthButtons(!!user);
    if (user) {
      hideAuthModal();
      try {
        await refreshApp();
      } catch (error) {
        console.error("Failed to load dashboard:", error);
      }
    } else {
      showNotLoggedInMessage();
      showAuthModal();
    }
  });
});

/* -------------------------------------------------------------------------- */
/* Function: bindUiHandlers                                                    */
/* Purpose: Attach all event listeners for the dashboard: modal open/close,  */
/*          auth form, source type toggle, form submit, and auth buttons.     */
/* -------------------------------------------------------------------------- */
function bindUiHandlers() {
  const newJobModal    = document.getElementById("new-job-modal");
  const resumeModal    = document.getElementById("resume-modal");

  const btnNewJob      = document.getElementById("btn-new-job");
  const btnManageResumes = document.getElementById("btn-manage-resumes");
  const cancelNewJob   = document.getElementById("cancel-new-job");
  const btnSignIn      = document.getElementById("btn-sign-in");
  const btnSignOut     = document.getElementById("btn-sign-out");
  const sourceType     = document.getElementById("source-type");
  const resumeSelect   = document.getElementById("resume-select");
  const newJobForm     = document.getElementById("new-job-form");

  // ---------------------------------------------------------------------------
  // Auth modal handlers
  // ---------------------------------------------------------------------------

  btnSignIn?.addEventListener("click", showAuthModal);

  btnSignOut?.addEventListener("click", async () => {
    await signOut();
    // onAuthChange fires automatically and shows the auth modal
  });

  document.getElementById("auth-form")?.addEventListener("submit", async (e) => {
    e.preventDefault();
    await handleAuthSubmit();
  });

  document.getElementById("btn-auth-toggle")?.addEventListener("click", toggleAuthMode);

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
/* Auth Modal
/* ================================================================================ */

function showAuthModal() {
  document.getElementById("auth-modal")?.classList.remove("hidden");
}

function hideAuthModal() {
  const modal = document.getElementById("auth-modal");
  modal?.classList.add("hidden");
  document.getElementById("auth-error")?.classList.add("hidden");
  document.getElementById("auth-form")?.reset();
}

/* -------------------------------------------------------------------------- */
/* Function: toggleAuthMode                                                    */
/* Purpose: Switch between Sign In and Create Account modes in the auth modal.*/
/* -------------------------------------------------------------------------- */
function toggleAuthMode() {
  authMode = authMode === "signin" ? "signup" : "signin";
  const isSignUp = authMode === "signup";
  const title  = document.getElementById("auth-modal-title");
  const submit = document.getElementById("btn-auth-submit");
  const toggle = document.getElementById("btn-auth-toggle");
  if (title)  title.textContent  = isSignUp ? "Create Account" : "Sign In";
  if (submit) submit.textContent = isSignUp ? "Create Account" : "Sign In";
  if (toggle) toggle.textContent = isSignUp ? "Sign In Instead" : "Create Account";
  document.getElementById("auth-error")?.classList.add("hidden");
}

/* -------------------------------------------------------------------------- */
/* Function: handleAuthSubmit                                                  */
/* Purpose: Dispatch the Firebase sign-in or sign-up call and show any       */
/*          error inline; on success Firebase triggers onAuthChange.          */
/* -------------------------------------------------------------------------- */
async function handleAuthSubmit() {
  const email    = document.getElementById("auth-email")?.value.trim()  || "";
  const password = document.getElementById("auth-password")?.value      || "";
  const errorEl  = document.getElementById("auth-error");
  const submitBtn = document.getElementById("btn-auth-submit");

  if (errorEl) { errorEl.textContent = ""; errorEl.classList.add("hidden"); }
  if (submitBtn) submitBtn.disabled = true;

  try {
    if (authMode === "signup") {
      await signUp(email, password);
    } else {
      await signIn(email, password);
    }
    // onAuthChange fires automatically — no manual UI update needed here
  } catch (error) {
    if (errorEl) {
      errorEl.textContent = formatFirebaseError(error);
      errorEl.classList.remove("hidden");
    }
  } finally {
    if (submitBtn) submitBtn.disabled = false;
  }
}

function formatFirebaseError(error) {
  const code = error.code || "";
  if (code === "auth/invalid-credential" ||
      code === "auth/user-not-found"     ||
      code === "auth/wrong-password")        return "Invalid email or password.";
  if (code === "auth/email-already-in-use")  return "Email is already in use.";
  if (code === "auth/weak-password")         return "Password must be at least 6 characters.";
  if (code === "auth/invalid-email")         return "Invalid email address.";
  return error.message || "Authentication failed.";
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
/*          based on the current Firebase auth state.                         */
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
