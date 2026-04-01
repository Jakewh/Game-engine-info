"use strict";

const PANEL_ID = "game-engine-info-row";
const ROUTE_POLL_MS = 800;
const RESULT_CACHE = new Map();
const PLUGIN_NAME = "game-engine-info";

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

function stripHtml(value) {
    return value
        .replace(/<[^>]+>/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

function parseEngineFromHtml(html) {
    try {
        const doc = new DOMParser().parseFromString(html, "text/html");
        const rows = doc.querySelectorAll("tr");
        for (const row of rows) {
            const header = row.querySelector("th");
            const value = row.querySelector("td");
            if (!header || !value) {
                continue;
            }
            const label = (header.textContent || "").trim();
            if (/^engine$/i.test(label) || /^game engine$/i.test(label)) {
                const result = (value.textContent || "").replace(/\s+/g, " ").trim();
                if (result) {
                    return result;
                }
            }
        }
    } catch {
        // Ignore parser errors and fallback to regex.
    }

    const htmlMatch = html.match(/(?:Game\s*)?Engine\s*<\/th>\s*<td[^>]*>(.*?)<\/td>/is);
    if (htmlMatch && htmlMatch[1]) {
        const result = stripHtml(htmlMatch[1]);
        if (result) {
            return result;
        }
    }

    const techMatch = html.match(/(?:^|\n)\s*Engine\s*\n\s*([^\n]+)/i);
    if (techMatch && techMatch[1]) {
        const result = stripHtml(techMatch[1]);
        if (result && !/^(n\/a|unknown|none)$/i.test(result)) {
            return result;
        }
    }

    const markdownMatch = html.match(/(?:^|\n)\s*(?:Game\s*)?Engine\s*\|\s*([^\n|]+)/i);
    if (markdownMatch && markdownMatch[1]) {
        const result = markdownMatch[1].trim();
        if (result) {
            return result;
        }
    }

    return null;
}

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

let lastAppId = null;
let activeRequestId = 0;

async function refreshForCurrentPage() {
    if (!document.body) {
        return;
    }

    const appId = getAppIdFromUrl();
    if (!appId) {
        const row = document.getElementById(PANEL_ID);
        if (row) {
            row.remove();
        }
        lastAppId = null;
        return;
    }

    if (appId === lastAppId) {
        if (RESULT_CACHE.has(appId) && !document.getElementById(PANEL_ID)) {
            setPanel(RESULT_CACHE.get(appId));
        }
        return;
    }

    lastAppId = appId;
    const requestId = ++activeRequestId;

    setPanel("loading...");

    try {
        const engine = await fetchEngine(appId);
        if (requestId !== activeRequestId) {
            return;
        }
        setPanel(engine);
    } catch {
        if (requestId !== activeRequestId) {
            return;
        }
        setPanel("not found");
    }
}

function start() {
    refreshForCurrentPage();
    window.setInterval(refreshForCurrentPage, ROUTE_POLL_MS);
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
} else {
    start();
}
