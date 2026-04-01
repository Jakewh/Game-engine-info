"use strict";

const PANEL_ID = "game-engine-info-row";
const LIBRARY_PANEL_ID = "game-engine-library-info";
const ROUTE_POLL_MS = 800;
const RESULT_CACHE = new Map();
const DISPLAY_CACHE = new Map();
const PLUGIN_NAME = "game-engine-info";

// ---------------------------------------------------------------------------
// Store context helpers (webkit.js — store.steampowered.com)
// ---------------------------------------------------------------------------

function isStoreLikeContext() {
    const href = String(window.location.href || "");
    const path = String(window.location.pathname || "");
    return href.includes("store.steampowered.com")
        || href.includes("steamcommunity.com")
        || /^\/app\//.test(path)
        || /^\/bundle\//.test(path)
        || /^\/sub\//.test(path);
}

function getAppIdFromUrl() {
    const match = window.location.pathname.match(/^\/app\/(\d+)/);
    return match ? match[1] : null;
}

function normalizeText(value) {
    return value.replace(/\s+/g, " ").trim();
}

function findReviewCzechRow() {
    const rows = Array.from(document.querySelectorAll(".user_reviews_summary_row"));
    let fallbackReviewRow = null;

    for (const row of rows) {
        const subtitle = row.querySelector(".subtitle");
        if (!subtitle) {
            continue;
        }

        const text = normalizeText(subtitle.textContent || "").toUpperCase();
        if (text.includes("RECENZE (ČEŠTINA)")) {
            return row;
        }

        if (!fallbackReviewRow && text.includes("RECENZE")) {
            fallbackReviewRow = row;
        }
    }

    if (rows.length > 1) {
        return rows[1];
    }

    return fallbackReviewRow || null;
}

function ensureInfoRow() {
    let row = document.getElementById(PANEL_ID);
    if (row) {
        return row;
    }

    const anchorRow = findReviewCzechRow();
    if (!anchorRow || !anchorRow.parentElement) {
        return null;
    }

    row = document.createElement("div");
    row.id = PANEL_ID;
    row.className = "user_reviews_summary_row";

    const label = document.createElement("span");
    label.className = "subtitle column";
    label.textContent = "Game engine: ";

    const value = document.createElement("span");
    value.className = "summary column";
    value.style.color = "#66c0f4";

    row.appendChild(label);
    row.appendChild(value);

    anchorRow.insertAdjacentElement("afterend", row);
    return row;
}

function setPanel(text) {
    const row = ensureInfoRow();
    if (!row) {
        return;
    }
    const value = row.lastElementChild;
    if (value) {
        value.textContent = text;
    }
}

// ---------------------------------------------------------------------------
// Backend bridge
// ---------------------------------------------------------------------------

async function fetchEngine(appId) {
    if (RESULT_CACHE.has(appId)) {
        return RESULT_CACHE.get(appId);
    }
    if (!window.Millennium || typeof window.Millennium.callServerMethod !== "function") {
        throw new Error("Millennium backend bridge unavailable");
    }

    const response = await window.Millennium.callServerMethod(PLUGIN_NAME, "GetEngine", {
        appid: Number(appId)
    });

    const raw = typeof response === "string"
        ? response
        : (typeof response?.returnValue === "string" ? response.returnValue : null);

    if (!raw) {
        throw new Error("Backend returned empty response");
    }

    const payload = JSON.parse(raw);
    if (!payload?.success || typeof payload.engine !== "string" || payload.engine.length === 0) {
        throw new Error(payload?.error || "Engine not found");
    }

    RESULT_CACHE.set(appId, payload.engine);
    return payload.engine;
}

// ---------------------------------------------------------------------------
// Library mode
// In the Millennium client module (index.js), `document` is the shell window,
// NOT the Library popup. We use AddWindowCreateHook (same pattern as
// hltb-for-millennium) to get the real popup document and inject there.
// ---------------------------------------------------------------------------

let libraryObserver = null;
let lastLibraryAppId = null;

function getLibraryCurrentAppId() {
    // MainWindowBrowserManager path looks like /app/868360, not /library/app/868360
    const pathname = window.MainWindowBrowserManager?.m_lastLocation?.pathname || "";
    const match = pathname.match(/\/app\/(\d+)/);
    return match ? match[1] : null;
}

function injectLibraryPanel(doc, text) {
    let panel = doc.getElementById(LIBRARY_PANEL_ID);
    if (!panel) {
        panel = doc.createElement("div");
        panel.id = LIBRARY_PANEL_ID;
        panel.style.position = "fixed";
        panel.style.top = "130px";
        panel.style.right = "16px";
        panel.style.zIndex = "999999";
        panel.style.display = "inline-flex";
        panel.style.alignItems = "center";
        panel.style.gap = "4px";
        panel.style.padding = "4px 8px";
        panel.style.background = "rgba(15, 23, 32, 0.85)";
        panel.style.border = "1px solid rgba(255,255,255,0.12)";
        panel.style.borderRadius = "6px";
        panel.style.fontSize = "14px";
        panel.style.lineHeight = "1.35";
        panel.style.color = "#9da8b3";

        const label = doc.createElement("span");
        label.textContent = "Game engine: ";

        const value = doc.createElement("span");
        value.style.color = "#66c0f4";
        value.style.fontWeight = "600";

        panel.appendChild(label);
        panel.appendChild(value);
        doc.body.appendChild(panel);
    }
    const value = panel.lastElementChild;
    if (value) {
        value.textContent = text;
    }
}

async function handleLibraryNavigation(doc) {
    const appId = getLibraryCurrentAppId();

    if (!appId) {
        doc.getElementById(LIBRARY_PANEL_ID)?.remove();
        lastLibraryAppId = null;
        return;
    }

    const cacheKey = "library:" + appId;

    if (appId === lastLibraryAppId) {
        // Re-inject if React re-render removed the panel
        if (DISPLAY_CACHE.has(cacheKey) && !doc.getElementById(LIBRARY_PANEL_ID)) {
            injectLibraryPanel(doc, DISPLAY_CACHE.get(cacheKey));
        }
        return;
    }

    lastLibraryAppId = appId;

    // Serve from cache instantly if available
    if (DISPLAY_CACHE.has(cacheKey)) {
        injectLibraryPanel(doc, DISPLAY_CACHE.get(cacheKey));
        return;
    }

    injectLibraryPanel(doc, "loading...");

    try {
        const engine = await fetchEngine(appId);
        DISPLAY_CACHE.set(cacheKey, engine);
        if (lastLibraryAppId === appId) {
            injectLibraryPanel(doc, engine);
        }
    } catch {
        const text = "not found";
        DISPLAY_CACHE.set(cacheKey, text);
        if (lastLibraryAppId === appId) {
            injectLibraryPanel(doc, text);
        }
    }
}

function setupLibraryOnDoc(doc) {
    if (libraryObserver) {
        libraryObserver.disconnect();
        libraryObserver = null;
    }

    const win = doc.defaultView || window;
    libraryObserver = new win.MutationObserver(() => {
        handleLibraryNavigation(doc);
    });
    libraryObserver.observe(doc.body, { childList: true, subtree: true });

    handleLibraryNavigation(doc);
}

function setupLibraryHook() {
    // Try existing popup first — may already be open when plugin loads
    try {
        const existing = window.g_PopupManager?.GetExistingPopup?.("SP Desktop_uid0");
        if (existing?.m_popup?.document?.body) {
            setupLibraryOnDoc(existing.m_popup.document);
        }
    } catch {
        // Ignore
    }

    // Hook into future popup creations (same pattern as hltb-for-millennium)
    window.Millennium?.AddWindowCreateHook?.(function(windowInfo) {
        if (!windowInfo.m_strName?.startsWith("SP ")) {
            return;
        }
        const doc = windowInfo.m_popup?.document;
        if (!doc?.body) {
            return;
        }
        setupLibraryOnDoc(doc);
    });
}

// ---------------------------------------------------------------------------
// Store poll loop
// ---------------------------------------------------------------------------

let lastViewKey = null;
let activeRequestId = 0;

async function refreshForCurrentPage() {
    if (!document.body) {
        return;
    }

    const appId = getAppIdFromUrl();
    if (!appId) {
        document.getElementById(PANEL_ID)?.remove();
        lastViewKey = null;
        return;
    }

    const viewKey = "store:" + appId;

    if (viewKey === lastViewKey) {
        const cached = DISPLAY_CACHE.get(viewKey);
        if (cached !== undefined && !document.getElementById(PANEL_ID)) {
            setPanel(cached);
        }
        return;
    }

    lastViewKey = viewKey;
    const requestId = ++activeRequestId;
    setPanel("loading...");

    try {
        const engine = await fetchEngine(appId);
        if (requestId !== activeRequestId) {
            return;
        }
        DISPLAY_CACHE.set(viewKey, engine);
        setPanel(engine);
    } catch {
        if (requestId !== activeRequestId) {
            return;
        }
        DISPLAY_CACHE.set(viewKey, "not found");
        setPanel("not found");
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function start() {
    if (isStoreLikeContext()) {
        // webkit.js: poll for Store page changes
        refreshForCurrentPage();
        window.setInterval(refreshForCurrentPage, ROUTE_POLL_MS);
    } else {
        // index.js (client module): hook into Library popup window
        setupLibraryHook();
    }
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
} else {
    start();
}
