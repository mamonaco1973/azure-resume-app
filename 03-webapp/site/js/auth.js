/* ========================================================================== */
/* auth.js                                                                     */
/* Entra External ID PKCE auth helpers. Token is stored in sessionStorage     */
/* after the code exchange in callback.html; cleared on sign-out.             */
/* ========================================================================== */

import { CONFIG } from "./config.js";

const TOKEN_KEY    = "entra_id_token";
const VERIFIER_KEY = "pkce_verifier";
const STATE_KEY    = "pkce_state";

// -----------------------------------------------------------------------------
// Token access
// -----------------------------------------------------------------------------

export async function getIdToken() {
  return sessionStorage.getItem(TOKEN_KEY) || "";
}

export function isLoggedIn() {
  const token = sessionStorage.getItem(TOKEN_KEY);
  if (!token) return false;
  try {
    const payload = JSON.parse(atob(token.split(".")[1]));
    return payload.exp > Date.now() / 1000;
  } catch {
    return false;
  }
}

// -----------------------------------------------------------------------------
// Auth operations
// -----------------------------------------------------------------------------

export function signIn() {
  const verifier = _generateVerifier();
  const state    = _generateState();
  sessionStorage.setItem(VERIFIER_KEY, verifier);
  sessionStorage.setItem(STATE_KEY,    state);

  _codeChallenge(verifier).then((challenge) => {
    const params = new URLSearchParams({
      client_id:             CONFIG.ENTRA_CLIENT_ID,
      response_type:         "code",
      redirect_uri:          CONFIG.REDIRECT_URI,
      // openid + client_id scope returns an id_token in the token response
      scope:                 `openid profile ${CONFIG.ENTRA_CLIENT_ID}`,
      code_challenge:        challenge,
      code_challenge_method: "S256",
      state,
    });
    window.location.href =
      `${CONFIG.ENTRA_AUTHORITY}/oauth2/v2.0/authorize?${params}`;
  });
}

export function signOut() {
  sessionStorage.removeItem(TOKEN_KEY);
  sessionStorage.removeItem(VERIFIER_KEY);
  sessionStorage.removeItem(STATE_KEY);
  const post = encodeURIComponent(
    `${window.location.origin}/index.html`
  );
  window.location.href =
    `${CONFIG.ENTRA_AUTHORITY}/oauth2/v2.0/logout?post_logout_redirect_uri=${post}`;
}

// -----------------------------------------------------------------------------
// Auth state subscription
// -----------------------------------------------------------------------------

export function onAuthChange(callback) {
  // Fires once synchronously — sessionStorage is available immediately,
  // no async restoration needed (unlike Firebase)
  callback(isLoggedIn() ? { token: sessionStorage.getItem(TOKEN_KEY) } : null);
}

export function waitForUser() {
  return Promise.resolve(
    isLoggedIn() ? { token: sessionStorage.getItem(TOKEN_KEY) } : null
  );
}

// -----------------------------------------------------------------------------
// PKCE helpers
// -----------------------------------------------------------------------------

function _generateVerifier() {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  return btoa(String.fromCharCode(...buf))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function _generateState() {
  const buf = new Uint8Array(16);
  crypto.getRandomValues(buf);
  return btoa(String.fromCharCode(...buf))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

async function _codeChallenge(verifier) {
  const data = new TextEncoder().encode(verifier);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
