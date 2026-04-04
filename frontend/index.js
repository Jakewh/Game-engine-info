"use strict";

const PANEL_ID = "game-engine-info-row";
const QUEUE_PANEL_ID = "game-engine-info-row-queue";
const LIBRARY_PANEL_ID = "game-engine-library-info";
const ROUTE_POLL_MS = 800;
const RESULT_CACHE = new Map();
const DISPLAY_CACHE = new Map();
const PLUGIN_NAME = "game-engine-info";
const STEAMDB_MODAL_ID = "game-engine-steamdb-modal";

let steamdbModalOpen = false;
let steamdbModalShown = false;

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

function extractAppIdFromText(value) {
    const text = String(value || "");
    const match = text.match(/\/app\/(\d+)/);
    return match ? match[1] : null;
}

function getAppIdFromLocation(loc) {
    if (!loc) {
        return null;
    }

    return extractAppIdFromText(loc.pathname) || extractAppIdFromText(loc.href);
}

function getAppIdFromDocument(doc, win) {
    const fromLocation = getAppIdFromLocation(win?.location);
    if (fromLocation) {
        return fromLocation;
    }

    const canonical = doc?.querySelector?.('link[rel="canonical"]')?.getAttribute("href");
    const fromCanonical = extractAppIdFromText(canonical);
    if (fromCanonical) {
        return fromCanonical;
    }

    const ogUrl = doc?.querySelector?.('meta[property="og:url"]')?.getAttribute("content");
    const fromOg = extractAppIdFromText(ogUrl);
    if (fromOg) {
        return fromOg;
    }

    return null;
}


function resolveStoreContext() {
    // Always prefer the main document — same approach as SteamDB extension.
    // The webkit.js script is injected directly into the store-page browser view,
    // so window.location and document are always the store page itself.
    const directAppId = getAppIdFromDocument(document, window);
    if (directAppId && document?.body) {
        return { appId: directAppId, doc: document };
    }

    // Fallback: scan same-origin iframes (e.g. queue wrapper pages).
    const frames = Array.from(document.querySelectorAll("iframe"));
    for (const frame of frames) {
        try {
            const frameDoc = frame.contentDocument;
            const frameWin = frame.contentWindow;
            if (!frameDoc?.body || !frameWin) {
                continue;
            }

            // Only use an iframe if it looks like a full store page.
            if (!frameDoc.querySelector("#userReviews, #appHubAppName, .apphub_AppName")) {
                continue;
            }
            const frameAppId = getAppIdFromDocument(frameDoc, frameWin) || extractAppIdFromText(frame.getAttribute("src"));
            if (frameAppId) {
                return { appId: frameAppId, doc: frameDoc };
            }
        } catch {
            // Cross-origin iframe or unavailable frame document.
        }
    }

    return { appId: null, doc: document };
}

function normalizeText(value) {
    return value.replace(/\s+/g, " ").trim();
}

function isQueueStorePage(winObj) {
    const winRef = winObj || window;
    const href = String(winRef?.location?.href || "");
    const search = String(winRef?.location?.search || "");
    return href.includes("queue=") || search.includes("queue=");
}

function findAllReviewsRow(targetDoc) {
    const doc = targetDoc || document;

    // "All Reviews" is always the first .user_reviews_summary_row inside #userReviews.
    // Prefer that over text matching to stay language-independent.
    const reviewsContainer = doc.getElementById("userReviews");
    if (reviewsContainer) {
        const first = reviewsContainer.querySelector(".user_reviews_summary_row");
        if (first) {
            return first;
        }
    }

    // Fallback: scan all summary rows and match common "all reviews" text patterns.
    const rows = Array.from(doc.querySelectorAll(".user_reviews_summary_row"));
    for (const row of rows) {
        const subtitle = row.querySelector(".subtitle");
        if (!subtitle) {
            continue;
        }
        const text = normalizeText(subtitle.textContent || "").toUpperCase();
        // Matches: "All Reviews:", "Všechny recenze:", "Wszystkie recenzje:", etc.
        if (text.includes("ALL REVIEWS") || text.includes("VŠECHNY") || text.includes("VŠECH")) {
            return row;
        }
    }

    // Last resort: first summary row in the document.
    return rows[0] || null;
}

function ensureInfoRow(targetDoc, options) {
    const opts = options || {};
    const forceFloating = Boolean(opts.forceFloating);
    const panelId = opts.panelId || PANEL_ID;
    const doc = targetDoc || document;
    let row = doc.getElementById(panelId);

    // If the panel already exists as a floating overlay but an inline anchor has
    // since appeared, remove it so we re-insert inline.
    if (row && !forceFloating && row.style.position === "fixed") {
        if (findAllReviewsRow(doc) || doc.getElementById("userReviews")) {
            row.remove();
            row = null;
        }
    }

    if (row) {
        return row;
    }

    const anchorRow = forceFloating ? null : findAllReviewsRow(doc);
    row = doc.createElement("div");
    row.id = panelId;
    row.className = anchorRow?.className || "user_reviews_summary_row";

    const label = doc.createElement("span");
    label.className = "subtitle column";
    label.textContent = "Game engine: ";

    const value = doc.createElement("span");
    value.className = "summary column";
    value.style.color = "#66c0f4";

    row.appendChild(label);
    row.appendChild(value);

    if (anchorRow && anchorRow.parentElement) {
        anchorRow.insertAdjacentElement("afterend", row);
    } else {
        // Second chance: append to #userReviews container (like SteamDB does).
        const reviewsContainer = doc.getElementById("userReviews") || doc.getElementById("userReviews_responsive");
        if (reviewsContainer) {
            const wrapper = doc.createElement("div");
            wrapper.appendChild(row);
            reviewsContainer.appendChild(wrapper);
        } else {
            // Ultimate fallback: fixed overlay when no review section is present.
            row.className = "";
            row.style.position = "fixed";
            row.style.top = "120px";
            row.style.right = "16px";
            row.style.zIndex = "999999";
            row.style.display = "inline-flex";
            row.style.alignItems = "center";
            row.style.gap = "4px";
            row.style.padding = "6px 10px";
            row.style.background = "rgba(15, 23, 32, 0.9)";
            row.style.border = "1px solid rgba(255,255,255,0.12)";
            row.style.borderRadius = "6px";
            row.style.fontSize = "14px";
            row.style.lineHeight = "1.35";
            row.style.color = "#9da8b3";

            label.className = "";
            value.className = "";
            value.style.fontWeight = "600";

            doc.body.appendChild(row);
        }
    }
    return row;
}

function setPanel(text, targetDoc, options) {
    const row = ensureInfoRow(targetDoc, options);
    if (!row) {
        return;
    }
    const value = row.lastElementChild;
    if (value) {
        value.textContent = text;
    }
}

function mirrorPanelToSameOriginFrames(text) {
    const frames = Array.from(document.querySelectorAll("iframe"));
    for (const frame of frames) {
        try {
            const frameDoc = frame.contentDocument;
            if (!frameDoc?.body) {
                continue;
            }

            setPanel(text, frameDoc, {
                forceFloating: true,
                panelId: QUEUE_PANEL_ID,
            });
        } catch {
            // Ignore cross-origin frames.
        }
    }
}

function clearMirroredPanels() {
    const frames = Array.from(document.querySelectorAll("iframe"));
    for (const frame of frames) {
        try {
            frame.contentDocument?.getElementById?.(QUEUE_PANEL_ID)?.remove();
        } catch {
            // Ignore cross-origin frames.
        }
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

async function callBackendMethod(methodName, payload) {
    if (!window.Millennium || typeof window.Millennium.callServerMethod !== "function") {
        throw new Error("Millennium backend bridge unavailable");
    }

    const response = await window.Millennium.callServerMethod(PLUGIN_NAME, methodName, payload || {});
    const raw = typeof response === "string"
        ? response
        : (typeof response?.returnValue === "string" ? response.returnValue : null);

    if (!raw) {
        throw new Error("Backend returned empty response");
    }

    return JSON.parse(raw);
}

async function loadSettings() {
    const payload = await callBackendMethod("GetSettings", {});
    if (!payload?.success || typeof payload.data !== "object" || payload.data === null) {
        throw new Error(payload?.error || "Failed to read settings");
    }
    return payload.data;
}

async function saveSettings(nextSettings) {
    const body = JSON.stringify(nextSettings || {});
    let payload = await callBackendMethod("SaveSettings", { settings_json: body });

    // Some hosts map positional args differently. Fallback to direct payload string.
    if (!payload?.success) {
        payload = await callBackendMethod("SaveSettings", body);
    }

    if (!payload?.success) {
        throw new Error(payload?.error || "Failed to save settings");
    }
}

function shouldOpenSteamDbSetup(error) {
    const msg = String(error?.message || error || "");
    return msg.includes("steamdb_cookie")
        || msg.includes("Cloudflare")
        || msg.includes("SteamDB blocked")
        || msg.includes("Web search HTTP 429");
}

async function openSteamDbSetupModal(afterSave, targetDoc) {
    const doc = targetDoc || document;
    if (!doc?.body) {
        return false;
    }

    if (steamdbModalOpen || doc.getElementById(STEAMDB_MODAL_ID)) {
        return false;
    }

    steamdbModalOpen = true;

    let currentCookie = "";
    try {
        const current = await loadSettings();
        currentCookie = String(current.steamdb_cookie || "");
    } catch {
        currentCookie = "";
    }

    const overlay = doc.createElement("div");
    overlay.id = STEAMDB_MODAL_ID;
    overlay.style.position = "fixed";
    overlay.style.inset = "0";
    overlay.style.zIndex = "1000000";
    overlay.style.background = "rgba(10, 16, 24, 0.72)";
    overlay.style.display = "flex";
    overlay.style.alignItems = "center";
    overlay.style.justifyContent = "center";

    const panel = doc.createElement("div");
    panel.style.width = "min(720px, 92vw)";
    panel.style.maxHeight = "80vh";
    panel.style.overflow = "auto";
    panel.style.borderRadius = "12px";
    panel.style.padding = "18px";
    panel.style.background = "linear-gradient(180deg, #1a2532 0%, #121b26 100%)";
    panel.style.border = "1px solid rgba(255,255,255,0.14)";
    panel.style.boxShadow = "0 20px 60px rgba(0,0,0,0.45)";
    panel.style.color = "#d7e3f0";
    panel.style.fontFamily = "\"Motiva Sans\", \"Noto Sans\", sans-serif";

    const title = doc.createElement("h3");
    title.textContent = "SteamDB setup required";
    title.style.margin = "0 0 10px 0";
    title.style.fontSize = "22px";

    const help = doc.createElement("p");
    help.textContent = "SteamDB blocks anonymous requests. Paste your SteamDB cookie string to enable fallback engine lookup.";
    help.style.margin = "0 0 10px 0";
    help.style.color = "#b9c9da";

    const help2 = doc.createElement("p");
    help2.textContent = "Expected format: cf_clearance=...; __cf_bm=...";
    help2.style.margin = "0 0 12px 0";
    help2.style.color = "#8fa5be";
    help2.style.fontSize = "13px";

    const guideTitle = doc.createElement("p");
    guideTitle.textContent = "How to get it (quick):";
    guideTitle.style.margin = "0 0 6px 0";
    guideTitle.style.color = "#b9c9da";
    guideTitle.style.fontSize = "13px";
    guideTitle.style.fontWeight = "700";

    const guideList = doc.createElement("ol");
    guideList.style.margin = "0 0 12px 20px";
    guideList.style.padding = "0";
    guideList.style.color = "#9fb3c8";
    guideList.style.fontSize = "12px";
    guideList.style.lineHeight = "1.45";

    const steps = [
        "Open steamdb.info in your web browser and pass Cloudflare check.",
        "Open browser Developer Tools (F12) and go to Application/Storage -> Cookies -> steamdb.info.",
        "Copy cf_clearance and __cf_bm values and paste them as one line into the field below.",
    ];
    for (const step of steps) {
        const li = doc.createElement("li");
        li.textContent = step;
        guideList.appendChild(li);
    }

    const input = doc.createElement("textarea");
    input.value = currentCookie;
    input.placeholder = "cf_clearance=...; __cf_bm=...";
    input.style.width = "100%";
    input.style.minHeight = "120px";
    input.style.padding = "10px";
    input.style.borderRadius = "8px";
    input.style.border = "1px solid rgba(255,255,255,0.18)";
    input.style.background = "#0f1722";
    input.style.color = "#dfe8f3";
    input.style.resize = "vertical";

    const status = doc.createElement("div");
    status.style.marginTop = "10px";
    status.style.minHeight = "20px";
    status.style.fontSize = "13px";
    status.style.color = "#f0c674";

    const actions = doc.createElement("div");
    actions.style.marginTop = "14px";
    actions.style.display = "flex";
    actions.style.gap = "10px";

    const saveBtn = doc.createElement("button");
    saveBtn.textContent = "Save and retry";
    saveBtn.style.padding = "8px 14px";
    saveBtn.style.borderRadius = "8px";
    saveBtn.style.border = "none";
    saveBtn.style.background = "#66c0f4";
    saveBtn.style.color = "#0c1a26";
    saveBtn.style.fontWeight = "700";
    saveBtn.style.cursor = "pointer";

    const closeBtn = doc.createElement("button");
    closeBtn.textContent = "Close";
    closeBtn.style.padding = "8px 14px";
    closeBtn.style.borderRadius = "8px";
    closeBtn.style.border = "1px solid rgba(255,255,255,0.25)";
    closeBtn.style.background = "transparent";
    closeBtn.style.color = "#dfe8f3";
    closeBtn.style.cursor = "pointer";

    const templateBtn = doc.createElement("button");
    templateBtn.textContent = "Copy template";
    templateBtn.style.padding = "8px 14px";
    templateBtn.style.borderRadius = "8px";
    templateBtn.style.border = "1px solid rgba(255,255,255,0.25)";
    templateBtn.style.background = "transparent";
    templateBtn.style.color = "#dfe8f3";
    templateBtn.style.cursor = "pointer";

    const closeModal = () => {
        overlay.remove();
        steamdbModalOpen = false;
    };

    closeBtn.addEventListener("click", closeModal);
    templateBtn.addEventListener("click", async () => {
        const template = "cf_clearance=...; __cf_bm=...";
        input.value = template;
        status.style.color = "#9ed0f4";
        status.textContent = "Template inserted into the input field.";

        if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
            try {
                await navigator.clipboard.writeText(template);
                status.textContent = "Template inserted and copied to clipboard.";
            } catch {
                // Clipboard may be blocked in embedded webviews.
            }
        }
    });
    overlay.addEventListener("click", (event) => {
        if (event.target === overlay) {
            closeModal();
        }
    });

    saveBtn.addEventListener("click", async () => {
        const cookie = String(input.value || "").trim();
        if (!cookie) {
            status.textContent = "Please paste a cookie value first.";
            return;
        }

        saveBtn.disabled = true;
        closeBtn.disabled = true;
        status.textContent = "Saving...";

        try {
            const current = await loadSettings();
            await saveSettings({ ...current, steamdb_cookie: cookie });
            status.style.color = "#8adf7f";
            status.textContent = "Saved. Retrying lookup...";
            closeModal();
            if (typeof afterSave === "function") {
                afterSave();
            }
        } catch (err) {
            status.style.color = "#f08a8a";
            status.textContent = "Save failed: " + String(err?.message || err || "unknown");
            saveBtn.disabled = false;
            closeBtn.disabled = false;
        }
    });

    actions.appendChild(saveBtn);
    actions.appendChild(templateBtn);
    actions.appendChild(closeBtn);

    panel.appendChild(title);
    panel.appendChild(help);
    panel.appendChild(help2);
    panel.appendChild(guideTitle);
    panel.appendChild(guideList);
    panel.appendChild(input);
    panel.appendChild(status);
    panel.appendChild(actions);

    overlay.appendChild(panel);
    doc.body.appendChild(overlay);
    return true;
}

async function maybePromptSteamDbSetup(error, onRetry, targetDoc) {
    if (steamdbModalShown || !shouldOpenSteamDbSetup(error)) {
        return;
    }
    const opened = await openSteamDbSetupModal(onRetry, targetDoc);
    if (opened) {
        steamdbModalShown = true;
    }
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
    } catch (error) {
        const text = "not found";
        DISPLAY_CACHE.set(cacheKey, text);
        if (lastLibraryAppId === appId) {
            injectLibraryPanel(doc, text);
        }
        await maybePromptSteamDbSetup(error, () => {
            RESULT_CACHE.delete(appId);
            DISPLAY_CACHE.delete(cacheKey);
            handleLibraryNavigation(doc);
        }, doc);
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
let inFlightViewKey = null;
let activeStoreDoc = null;

function renderStorePanel(text, storeDoc) {
    // storeDoc is always document or a same-origin iframe that looks like a store page.
    // ensureInfoRow handles anchor selection and #userReviews container fallback.
    setPanel(text, storeDoc, {
        forceFloating: false,
        panelId: PANEL_ID,
    });

    document.getElementById(QUEUE_PANEL_ID)?.remove();
    clearMirroredPanels();
}

async function refreshForCurrentPage() {
    if (!document.body) {
        return;
    }

    const storeContext = resolveStoreContext();
    const appId = storeContext.appId;
    const storeDoc = storeContext.doc || document;
    if (!appId) {
        activeStoreDoc?.getElementById?.(PANEL_ID)?.remove();
        document.getElementById(PANEL_ID)?.remove();
        document.getElementById(QUEUE_PANEL_ID)?.remove();
        clearMirroredPanels();
        lastViewKey = null;
        inFlightViewKey = null;
        activeStoreDoc = null;
        return;
    }

    activeStoreDoc = storeDoc;

    const viewKey = "store:" + appId;

    if (viewKey === lastViewKey) {
        const cached = DISPLAY_CACHE.get(viewKey);
        const existingPanel = storeDoc.getElementById(PANEL_ID) || document.getElementById(PANEL_ID);
        // Re-render if panel is missing OR if it's a floating overlay that could now be placed inline.
        const panelNeedsUpdate = !existingPanel || existingPanel.style.position === "fixed";
        if (cached !== undefined && panelNeedsUpdate) {
            renderStorePanel(cached, storeDoc);
        } else if (cached === undefined && !existingPanel) {
            // Steam often re-renders the page shell; keep the panel visible while waiting.
            renderStorePanel("loading...", storeDoc);
        }

        // If an old request got lost/stuck, allow a clean retry on the same page.
        if (cached === undefined && inFlightViewKey !== viewKey) {
            lastViewKey = null;
        }
        return;
    }

    lastViewKey = viewKey;
    inFlightViewKey = viewKey;
    const requestId = ++activeRequestId;
    renderStorePanel("loading...", storeDoc);

    try {
        const engine = await fetchEngine(appId);
        if (requestId !== activeRequestId) {
            return;
        }
        DISPLAY_CACHE.set(viewKey, engine);
        if (inFlightViewKey === viewKey) {
            inFlightViewKey = null;
        }
        renderStorePanel(engine, storeDoc);
    } catch (error) {
        if (requestId !== activeRequestId) {
            return;
        }
        DISPLAY_CACHE.set(viewKey, "not found");
        if (inFlightViewKey === viewKey) {
            inFlightViewKey = null;
        }
        renderStorePanel("not found", storeDoc);
        await maybePromptSteamDbSetup(error, () => {
            RESULT_CACHE.delete(appId);
            DISPLAY_CACHE.delete(viewKey);
            refreshForCurrentPage();
        }, storeDoc);
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function start() {
    // Run both modes to handle dynamic context switches inside the Steam client.
    refreshForCurrentPage();
    window.setInterval(refreshForCurrentPage, ROUTE_POLL_MS);

    // index.js (client module): hook into Library popup window
    setupLibraryHook();
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
} else {
    start();
}
