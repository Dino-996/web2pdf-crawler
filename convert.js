#!/usr/bin/env node

import puppeteer from "puppeteer-core";
import fs from "fs";
import fsp from "fs/promises";
import path from "path";
import os from "os";
import crypto from "crypto";
import { execSync } from "child_process";

// -------------------------------------------------------------
// PARAMETRI
// -------------------------------------------------------------
const siteUrl = process.argv[2];
const MAX_DEPTH = parseInt(process.argv[3] || "2");
const MAX_CONCURRENT = parseInt(process.argv[4] || "3");
const PDF_DIR = `pdf_${new Date().toISOString().replace(/[:.]/g, "_")}`;
const FAILED_LOG = path.join(PDF_DIR, "failed.log");

if (!siteUrl || !siteUrl.startsWith("http")) {
    console.error("Uso: node convert.js <URL> [profondità_max] [processi_paralleli]");
    process.exit(1);
}

// -------------------------------------------------------------
// AUTODETECT BRAVE
// -------------------------------------------------------------
function detectBrave() {
    const candidate = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
    if (fs.existsSync(candidate)) return candidate;

    try {
        const results = execSync(`mdfind "Brave Browser.app"`).toString().trim().split("\n");
        for (const appPath of results) {
            if (appPath.endsWith(".app")) {
                const execPath = path.join(appPath, "Contents/MacOS/Brave Browser");
                if (fs.existsSync(execPath)) return execPath;
            }
        }
    } catch {}
    console.error("❌ Brave non trovato.");
    process.exit(1);
}

const bravePath = detectBrave();

// -------------------------------------------------------------
// AUTODETECT PROFILO BRAVE
// -------------------------------------------------------------
function detectBraveProfile() {
    const macProfile = path.join(
        os.homedir(),
        "Library/Application Support/BraveSoftware/Brave-Browser/Default"
    );
    if (fs.existsSync(macProfile)) return macProfile;

    console.error("❌ Profilo Brave non trovato.");
    process.exit(1);
}

const profilePath = detectBraveProfile();

// -------------------------------------------------------------
// Utility sleep
// -------------------------------------------------------------
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

// -------------------------------------------------------------
// Rimuovi cookie banner dinamici
// -------------------------------------------------------------
async function removeCookieBanner(page) {
    const selectors = [
        "#cookie-banner","#cookieBanner","#cookies-banner","#cookies",
        "#cookie-consent","#cookieConsent",
        ".cookie-banner",".cookieBanner",".cookie-consent",".cookieConsent",
        ".cc-window",".cc-banner",".cky-consent-container",
        "[id*='cookie']","[class*='cookie']"
    ];

    for (let i = 0; i < 5; i++) {
        await page.evaluate((selectors) => {
            selectors.forEach(sel => {
                document.querySelectorAll(sel).forEach(el => {
                    el.style.display = "none";
                    el.remove?.();
                });
            });

            document.querySelectorAll("*").forEach(el => {
                const style = getComputedStyle(el);
                if ((style.position === "fixed" || style.position === "sticky") &&
                    el.innerText.toLowerCase().includes("cookie")) {
                    el.style.display = "none";
                    el.remove?.();
                }
            });

            // iframe per Iubenda, Cookiebot, OneTrust
            document.querySelectorAll("iframe").forEach(f => {
                const src = f.src.toLowerCase();
                if (src.includes("iubenda") || src.includes("cookie") || src.includes("onetrust")) {
                    f.style.display = "none";
                    f.remove?.();
                }
            });
        }, selectors);
        await sleep(500);
    }
}

// -------------------------------------------------------------
// Converti URL in nome file univoco
// -------------------------------------------------------------
function urlToFilename(url) {
    const base = url.replace(/^https?:\/\//, '').replace(/\/$/, '').replace(/\//g, '_').replace(/[^a-zA-Z0-9._-]/g, '');
    const hash = crypto.createHash('md5').update(url).digest('hex').slice(0,6);
    return `${base}_${hash}.pdf`;
}

// -------------------------------------------------------------
// Crawl dinamico e PDF
// -------------------------------------------------------------
async function crawlPage(page, url, depth, visited) {
    if (depth > MAX_DEPTH || visited.has(url)) return;
    visited.add(url);

    try {
        await page.goto(url, { waitUntil: "networkidle2" });
        await removeCookieBanner(page);

        const filename = path.join(PDF_DIR, urlToFilename(url));
        await fsp.mkdir(path.dirname(filename), { recursive: true });
        await page.pdf({
            path: filename,
            format: "A4",
            printBackground: true,
            margin: { top: "20mm", bottom: "20mm", left: "15mm", right: "15mm" }
        });

        console.log("✅ PDF:", url);

        const links = await page.evaluate(() =>
            Array.from(document.querySelectorAll('a[href]'))
                .map(a => a.href)
                .filter(h => h.startsWith(location.origin))
        );

        for (const link of links) {
            await crawlPage(page, link, depth + 1, visited);
        }

    } catch (err) {
        fs.appendFileSync(FAILED_LOG, `${new Date().toISOString()} FAILED: ${url}\n`);
        console.error("❌", url, "-", err.message);
    }
}

// -------------------------------------------------------------
// Main
// -------------------------------------------------------------
(async () => {
    console.log("🦁 Brave:", bravePath);
    console.log("📁 Profilo:", profilePath);

    await fsp.mkdir(PDF_DIR, { recursive: true });

    const browser = await puppeteer.launch({
        executablePath: bravePath,
        headless: true,
        args: [
            `--user-data-dir=${profilePath}`,
            "--disable-gpu",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--disable-features=SameSiteByDefaultCookies,CookiesWithoutSameSiteMustBeSecure"
        ]
    });

    const page = await browser.newPage();
    page.setDefaultNavigationTimeout(60000);

    const visited = new Set();
    await crawlPage(page, siteUrl, 0, visited);

    await browser.close();

    console.log("\n✨ Conversione completata!");
    console.log(`📄 PDF creati: ${visited.size}`);
    if (fs.existsSync(FAILED_LOG)) {
        const failedCount = fs.readFileSync(FAILED_LOG, "utf-8").trim().split("\n").length;
        console.log(`📄 Falliti: ${failedCount} (vedi ${FAILED_LOG})`);
    }
    console.log(`📁 Cartella PDF: ${PDF_DIR}`);
})();
