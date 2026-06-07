/* ========================================================================== */
/* app.js                                                                      */
/* Dashboard controller. Initializes Entra auth state, wires up the new-job  */
/* form, resume selector, folder management, and job list on DOMContentLoaded.*/
/* ========================================================================== */

import { register, createJob, listResumes, getUsage,
         listFolders, createFolder, deleteFolder } from "./api.js";
import { loadJobs, hasPendingJobs,
         setFolderFilter, setStatusFilter,
         setSearchFilter }                         from "./jobs.js";
import { bindResumeHandlers, openResumeManager }   from "./resumes.js";
import { isLoggedIn, signIn, signOut }             from "./auth.js";
import { showAlert, showConfirm, showPrompt }       from "./modal.js";

let lastSelectedResumeId = "";
let autoRefreshTimer     = null;
let countdownInterval    = null;
let folders              = [];
let currentFolderId      = "";

const AUTO_REFRESH_SECONDS = 5;

document.addEventListener("DOMContentLoaded", async () => {
  updateAuthButtons();
  bindUiHandlers();
  bindResumeHandlers();

  if (!isLoggedIn()) {
    showNotLoggedInMessage();
    return;
  }

  // Enforce user cap before loading the dashboard. 403 means the app is full.
  try {
    await register();
  } catch (error) {
    if (error.message && error.message.includes("User limit reached")) {
      await showAlert(
        "This app has reached its user limit. Please contact mamonaco1973@gmail.com.",
        { title: "Access Denied" }
      );
      signOut();
      return;
    }
  }

  try {
    restoreFilterState();
    await loadFolders();
    await refreshApp();
    await updateTokenUsage();
  } catch (error) {
    console.error("Failed to load dashboard:", error);
  }
});

/* -------------------------------------------------------------------------- */
/* Function: bindUiHandlers                                                    */
/* Purpose: Attach all event listeners for the dashboard: modal open/close,  */
/*          source type toggle, form submit, live validation, folder ops,     */
/*          filter bar, help modal, and auth buttons.                         */
/* -------------------------------------------------------------------------- */
function bindUiHandlers() {
  const newJobModal = document.getElementById("new-job-modal");
  const resumeModal = document.getElementById("resume-modal");

  const btnNewJob        = document.getElementById("btn-new-job");
  const btnManageResumes = document.getElementById("btn-manage-resumes");
  const cancelNewJob     = document.getElementById("cancel-new-job");
  const btnSignIn        = document.getElementById("btn-sign-in");
  const btnSignOut       = document.getElementById("btn-sign-out");
  const sourceType       = document.getElementById("source-type");
  const resumeSelect     = document.getElementById("resume-select");
  const newJobForm       = document.getElementById("new-job-form");

  // ---------------------------------------------------------------------------
  // Track last selected resume
  // ---------------------------------------------------------------------------

  resumeSelect?.addEventListener("change", () => {
    lastSelectedResumeId = resumeSelect.value;
  });

  // ---------------------------------------------------------------------------
  // Open "Score New Job"
  // ---------------------------------------------------------------------------

  btnNewJob?.addEventListener("click", async () => {
    try {
      resumeModal?.classList.add("hidden");
      resetNewJobForm();
      const hasResumes = await populateResumeSelect();
      if (!hasResumes) {
        await showAlert(
          "Please define a resume before scoring a job.",
          { title: "No Resume Found" }
        );
        await openResumeManager();
        return;
      }
      populateJobFolderSelect();
      updateSourceFields();
      newJobModal?.classList.remove("hidden");
      updateNewJobFormValidation();
    } catch (error) {
      await showAlert(`Failed to load resumes: ${error.message}`, { title: "Error" });
    }
  });

  // ---------------------------------------------------------------------------
  // Open "Manage Resumes"
  // ---------------------------------------------------------------------------

  btnManageResumes?.addEventListener("click", async () => {
    newJobModal?.classList.add("hidden");
    await openResumeManager();
  });

  // ---------------------------------------------------------------------------
  // Cancel new job modal
  // ---------------------------------------------------------------------------

  cancelNewJob?.addEventListener("click", () => {
    newJobModal?.classList.add("hidden");
  });

  // ---------------------------------------------------------------------------
  // Source type toggle
  // ---------------------------------------------------------------------------

  sourceType?.addEventListener("change", () => {
    setCookie("jobFilter_sourceType", sourceType.value);
    updateSourceFields();
    updateNewJobFormValidation();
  });

  // ---------------------------------------------------------------------------
  // Live validation listeners
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Folder dropdown
  // ---------------------------------------------------------------------------

  document.getElementById("folder-select")?.addEventListener("change", (e) => {
    currentFolderId = e.target.value;
    setFolderFilter(currentFolderId);
    setCookie("jobFilter_folder", currentFolderId);
    updateDeleteFolderButton();
    refreshApp();
  });

  document.getElementById("btn-new-folder")?.addEventListener("click", async () => {
    const name = await showPrompt("Folder name", {
      title: "New Folder", placeholder: "Enter folder name...", confirmText: "Create",
    });
    if (!name) return;
    if (folders.some((f) => f.name.toLowerCase() === name.toLowerCase())) {
      await showAlert(`A folder named "${name}" already exists.`, { title: "Duplicate Folder" });
      return;
    }
    try {
      await createFolder({ name });
      await loadFolders();
    } catch (error) {
      await showAlert(`Failed to create folder: ${error.message}`, { title: "Error" });
    }
  });

  document.getElementById("btn-delete-folder")?.addEventListener("click", async () => {
    if (!currentFolderId) return;
    const folder = folders.find((f) => f.folder_id === currentFolderId);
    const label  = folder?.name || currentFolderId;
    const confirmed = await showConfirm(
      `Delete folder "${label}"? Jobs inside will move to All Jobs.`,
      { title: "Delete Folder", confirmText: "Delete", danger: true }
    );
    if (!confirmed) return;
    try {
      await deleteFolder(currentFolderId);
      currentFolderId = "";
      setFolderFilter("");
      setCookie("jobFilter_folder", "");
      await loadFolders();
      await refreshApp();
    } catch (error) {
      await showAlert(`Failed to delete folder: ${error.message}`, { title: "Error" });
    }
  });

  // ---------------------------------------------------------------------------
  // Filter bar — status + search
  // ---------------------------------------------------------------------------

  document.getElementById("filter-status")?.addEventListener("change", (e) => {
    setStatusFilter(e.target.value);
    setCookie("jobFilter_status", e.target.value);
    refreshApp();
  });

  document.getElementById("filter-search")?.addEventListener("input", (e) => {
    setSearchFilter(e.target.value);
    setCookie("jobFilter_search", e.target.value);
    refreshApp();
  });

  // ---------------------------------------------------------------------------
  // Help modal
  // ---------------------------------------------------------------------------

  const helpModal = document.getElementById("help-modal");
  document.getElementById("btn-help")?.addEventListener("click", () => {
    helpModal?.classList.remove("hidden");
  });
  document.getElementById("btn-help-close")?.addEventListener("click", () => {
    helpModal?.classList.add("hidden");
  });
  helpModal?.addEventListener("click", (e) => {
    if (e.target === helpModal) helpModal.classList.add("hidden");
  });

  // ---------------------------------------------------------------------------
  // Sign-in modal — preview shown first; actual redirect triggered inside modal
  // ---------------------------------------------------------------------------

  const signInModal = document.getElementById("sign-in-modal");

  btnSignIn?.addEventListener("click", () => {
    signInModal?.classList.remove("hidden");
  });

  document.getElementById("btn-entra-sign-in")?.addEventListener("click", () => {
    signIn();
  });

  // ---------------------------------------------------------------------------
  // Sign out
  // ---------------------------------------------------------------------------

  btnSignOut?.addEventListener("click", () => {
    signOut();
  });
}

/* -------------------------------------------------------------------------- */
/* Function: updateSourceFields                                                */
/* Purpose: Show only the input field matching the selected source type.      */
/* -------------------------------------------------------------------------- */
function updateSourceFields() {
  const sourceType    = document.getElementById("source-type");
  const urlField      = document.getElementById("url-field");
  const textField     = document.getElementById("text-field");
  const linkedinField = document.getElementById("linkedin-field");
  if (!sourceType) return;
  urlField?.classList.add("hidden");
  textField?.classList.add("hidden");
  linkedinField?.classList.add("hidden");
  if (sourceType.value === "url")             urlField?.classList.remove("hidden");
  if (sourceType.value === "raw_text")        textField?.classList.remove("hidden");
  if (sourceType.value === "linkedin_job_id") linkedinField?.classList.remove("hidden");
}

/* -------------------------------------------------------------------------- */
/* Function: populateResumeSelect                                              */
/* Purpose: Fetch all resumes and rebuild the resume dropdown. Restores the   */
/*          last-used selection when possible; falls back to the first item.  */
/* -------------------------------------------------------------------------- */
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
    return false;
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
  return true;
}

/* -------------------------------------------------------------------------- */
/* Function: resetNewJobForm                                                   */
/* Purpose: Clear all new-job form fields and restore the saved source type.  */
/* -------------------------------------------------------------------------- */
function resetNewJobForm() {
  document.getElementById("new-job-form")?.reset();
  const savedSourceType = getCookie("jobFilter_sourceType") || "linkedin_job_id";
  document.getElementById("source-type").value = savedSourceType;
  document.getElementById("job-url").value = "";
  document.getElementById("job-description").value = "";
  document.getElementById("linkedin-job-ids").value = "";
  updateSourceFields();
}

/* -------------------------------------------------------------------------- */
/* Function: validateNewJobForm                                                */
/* Purpose: Collect and validate all new-job form inputs. Returns isValid     */
/*          and an errors map keyed by field name.                            */
/* -------------------------------------------------------------------------- */
function validateNewJobForm() {
  const errors      = {};
  const resumeId    = document.getElementById("resume-select")?.value.trim()        || "";
  const sourceType  = document.getElementById("source-type")?.value                 || "url";
  const jobUrl      = document.getElementById("job-url")?.value.trim()              || "";
  const jobDesc     = document.getElementById("job-description")?.value.trim()      || "";
  const linkedinRaw = document.getElementById("linkedin-job-ids")?.value.trim()     || "";
  const resumeSel   = document.getElementById("resume-select");
  const hasResumes  = Array.from(resumeSel?.options || []).some((o) => o.value.trim());

  if (!resumeId) {
    errors.resume = hasResumes
      ? "You must select a resume."
      : "Please add a resume with Manage Resumes.";
  }
  if (sourceType === "url") {
    if (!jobUrl)                errors.jobUrl = "Job URL is required.";
    else if (!isValidUrl(jobUrl)) errors.jobUrl = "URL is invalid. Enter a valid http or https URL.";
  }
  if (sourceType === "raw_text") {
    if (!jobDesc)               errors.jobDescription = "Job description is required.";
    else if (jobDesc.length < 100) errors.jobDescription = "Job description is too short.";
  }
  if (sourceType === "linkedin_job_id") {
    const ids = parseLinkedInJobIds(linkedinRaw);
    if (!ids.length)                         errors.linkedinJobIds = "Enter at least one LinkedIn job ID.";
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

/* -------------------------------------------------------------------------- */
/* Function: submitJobScoringRequest                                           */
/* Purpose: Read the selected source type and dispatch the appropriate        */
/*          createJob call. LinkedIn IDs are expanded to individual URL jobs. */
/* -------------------------------------------------------------------------- */
async function submitJobScoringRequest() {
  const resumeId   = document.getElementById("resume-select")?.value.trim() || "";
  const sourceType = document.getElementById("source-type")?.value          || "url";
  const folderId   = document.getElementById("new-job-folder-select")?.value || null;
  const base       = { resume_id: resumeId, ...(folderId ? { folder_id: folderId } : {}) };

  if (sourceType === "url") {
    await createJob({
      ...base,
      source_type: "url",
      job_url: document.getElementById("job-url")?.value.trim() || "",
    });
    return;
  }

  if (sourceType === "raw_text") {
    await createJob({
      ...base,
      source_type: "raw_text",
      job_description: document.getElementById("job-description")?.value.trim() || "",
    });
    return;
  }

  if (sourceType === "linkedin_job_id") {
    const ids = (document.getElementById("linkedin-job-ids")?.value.trim() || "")
      .split("\n").map((id) => id.trim()).filter(Boolean);
    for (const id of ids) {
      await createJob({
        ...base,
        source_type: "url",
        job_url: `https://www.linkedin.com/jobs/view/${id}`,
      });
    }
  }
}

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

/* -------------------------------------------------------------------------- */
/* Function: refreshApp                                                        */
/* Purpose: Reload the job list and token usage from the API and re-render.  */
/* -------------------------------------------------------------------------- */
async function refreshApp() {
  if (countdownInterval !== null) { clearInterval(countdownInterval); countdownInterval = null; }
  const refreshButton = document.getElementById("btn-refresh");
  const table         = document.getElementById("jobs-table");
  try {
    if (refreshButton) refreshButton.disabled = true;
    table?.classList.add("loading");
    await loadJobs();
    await updateTokenUsage();
  } catch (error) {
    console.error("Failed to refresh dashboard:", error);
    await showAlert(`Failed to refresh jobs: ${error.message}`, { title: "Error" });
  } finally {
    if (refreshButton) refreshButton.disabled = false;
    table?.classList.remove("loading");
    scheduleAutoRefresh();
  }
}

/* -------------------------------------------------------------------------- */
/* Function: updateAuthButtons                                                 */
/* Purpose: Toggle sign-in/sign-out visibility and enable or disable action   */
/*          buttons based on whether the user is currently authenticated.     */
/* -------------------------------------------------------------------------- */
function updateAuthButtons() {
  const loggedIn = isLoggedIn();

  document.getElementById("btn-sign-in")?.classList.toggle("hidden",  loggedIn);
  document.getElementById("btn-sign-out")?.classList.toggle("hidden", !loggedIn);
  document.getElementById("filter-bar")?.classList.toggle("hidden",   !loggedIn);

  if (!loggedIn) {
    document.getElementById("token-usage")?.classList.add("hidden");
  }

  for (const id of ["btn-refresh", "btn-new-job", "btn-manage-resumes"]) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (loggedIn) el.removeAttribute("disabled");
    else          el.setAttribute("disabled", "true");
  }
}

/* ================================================================================
/* Folders
/* ================================================================================ */

/* -------------------------------------------------------------------------- */
/* Function: loadFolders                                                       */
/* Purpose: Fetch the folder list and repopulate the folder dropdown,         */
/*          preserving the current selection when it still exists.            */
/* -------------------------------------------------------------------------- */
async function loadFolders() {
  try {
    folders = await listFolders();
  } catch (_) {
    folders = [];
  }

  const select = document.getElementById("folder-select");
  if (!select) return;

  select.innerHTML = `<option value="">All Jobs</option>`;
  folders.forEach((f) => {
    const opt = document.createElement("option");
    opt.value       = f.folder_id;
    opt.textContent = f.name;
    select.appendChild(opt);
  });

  const stillValid = folders.some((f) => f.folder_id === currentFolderId);
  if (!stillValid) { currentFolderId = ""; setCookie("jobFilter_folder", ""); }
  select.value = currentFolderId;
  setFolderFilter(currentFolderId);
  updateDeleteFolderButton();
}

function updateDeleteFolderButton() {
  const btn = document.getElementById("btn-delete-folder");
  if (!btn) return;
  if (currentFolderId) btn.classList.remove("hidden");
  else                 btn.classList.add("hidden");
}

function populateJobFolderSelect() {
  const select = document.getElementById("new-job-folder-select");
  if (!select) return;
  select.innerHTML = `<option value="">No Folder</option>`;
  folders.forEach((f) => {
    const opt = document.createElement("option");
    opt.value       = f.folder_id;
    opt.textContent = f.name;
    select.appendChild(opt);
  });
  select.value = currentFolderId || "";
}

/* -------------------------------------------------------------------------- */
/* Function: restoreFilterState                                                */
/* Purpose: Read saved filter cookies and apply them to the filter bar and    */
/*          in-memory state before the first data load.                       */
/* -------------------------------------------------------------------------- */
function restoreFilterState() {
  const savedFolder = getCookie("jobFilter_folder");
  const savedStatus = getCookie("jobFilter_status");
  const savedSearch  = getCookie("jobFilter_search");

  if (savedFolder) currentFolderId = savedFolder;

  const statusEl = document.getElementById("filter-status");
  const searchEl = document.getElementById("filter-search");
  if (savedStatus && statusEl) { statusEl.value = savedStatus; setStatusFilter(savedStatus); }
  if (savedSearch  && searchEl) { searchEl.value = savedSearch;  setSearchFilter(savedSearch); }
}

/* ================================================================================
/* Cookie Helpers
/* ================================================================================ */

function setCookie(name, value) {
  const expires = new Date(Date.now() + 30 * 864e5).toUTCString();
  document.cookie = `${name}=${encodeURIComponent(value)}; expires=${expires}; path=/; SameSite=Lax`;
}

function getCookie(name) {
  return document.cookie.split("; ").reduce((found, part) => {
    const [k, v] = part.split("=");
    return k === name ? decodeURIComponent(v || "") : found;
  }, "");
}

/* -------------------------------------------------------------------------- */
/* Function: updateTokenUsage                                                  */
/* Purpose: Fetch the user's current AOAI token usage and update the SVG ring */
/*          indicator in the filter bar. Swallows errors to never block load. */
/* -------------------------------------------------------------------------- */
async function updateTokenUsage() {
  try {
    const data      = await getUsage();
    const used      = data?.tokens_used ?? 0;
    const limit     = data?.token_limit ?? 100000;
    const remaining = Math.max(0, limit - used);
    const usedPct   = limit > 0 ? Math.min((used / limit) * 100, 100) : 0;
    const leftPct   = 100 - usedPct;

    const arc     = document.getElementById("token-ring-arc");
    const label   = document.getElementById("token-usage-label");
    const display = document.getElementById("token-usage");
    if (!arc || !label) return;

    // Arc represents remaining tokens — starts full and depletes
    arc.setAttribute("stroke-dasharray", `${leftPct.toFixed(1)} ${usedPct.toFixed(1)}`);
    arc.classList.toggle("token-near-limit", usedPct >= 80);

    const fmt = (n) => n >= 1000 ? `${(n / 1000).toFixed(1)}K` : String(n);
    label.textContent = `${fmt(remaining)} / ${fmt(limit)}`;
    label.title       = `${used.toLocaleString()} of ${limit.toLocaleString()} tokens used (${usedPct.toFixed(1)}%)`;

    // Reveal only after data is populated — avoids showing an empty ring on load
    display?.classList.remove("hidden");
  } catch (_) {
    // Token display is non-critical — fail silently
  }
}

/* -------------------------------------------------------------------------- */
/* Function: showNotLoggedInMessage                                            */
/* Purpose: Hide the jobs table and replace the empty state with a sign-in   */
/*          prompt, then auto-open the sign-in modal.                        */
/* -------------------------------------------------------------------------- */
function showNotLoggedInMessage() {
  document.getElementById("jobs-table")?.classList.add("hidden");
  const emptyState = document.getElementById("empty-state");
  if (emptyState) {
    emptyState.classList.remove("hidden");
    emptyState.innerHTML = "<p>Please sign in to use the application.</p>";
  }
  // Auto-open sign-in modal for unauthenticated visitors
  document.getElementById("sign-in-modal")?.classList.remove("hidden");
}
