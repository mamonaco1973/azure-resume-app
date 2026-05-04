/* ========================================================================== */
/* auth.js                                                                     */
/* Firebase Auth helpers: initialise the Firebase app, manage sign-in/out,   */
/* and vend fresh ID tokens for API requests.                                 */
/* ========================================================================== */

import { initializeApp }                        from "firebase/app";
import {
  getAuth,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  createUserWithEmailAndPassword,
  signOut as fbSignOut
} from "firebase/auth";

import { CONFIG } from "./config.js";

// -----------------------------------------------------------------------------
// Firebase Initialisation
// -----------------------------------------------------------------------------

const app  = initializeApp({
  apiKey:    CONFIG.apiKey,
  authDomain: CONFIG.authDomain,
  projectId: CONFIG.projectId,
});

export const auth = getAuth(app);

// -----------------------------------------------------------------------------
// Token access — Firebase auto-refreshes tokens before they expire
// -----------------------------------------------------------------------------

export async function getIdToken() {
  const user = auth.currentUser;
  if (!user) return "";
  return user.getIdToken();
}

export function isLoggedIn() {
  return !!auth.currentUser;
}

// -----------------------------------------------------------------------------
// Auth operations
// -----------------------------------------------------------------------------

export async function signIn(email, password) {
  return signInWithEmailAndPassword(auth, email, password);
}

export async function signUp(email, password) {
  return createUserWithEmailAndPassword(auth, email, password);
}

export async function signOut() {
  return fbSignOut(auth);
}

// -----------------------------------------------------------------------------
// Auth state subscription
// -----------------------------------------------------------------------------

export function onAuthChange(callback) {
  return onAuthStateChanged(auth, callback);
}

/* -------------------------------------------------------------------------- */
/* Function: waitForUser                                                        */
/* Purpose: Resolve with the current user once Firebase has restored the      */
/*          session from storage. Avoids acting on a null currentUser that    */
/*          exists only because initialisation hasn't completed yet.          */
/* -------------------------------------------------------------------------- */
export function waitForUser() {
  return new Promise((resolve) => {
    const unsubscribe = onAuthStateChanged(auth, (user) => {
      unsubscribe();
      resolve(user);
    });
  });
}
