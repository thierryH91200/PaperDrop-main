# App Store listing — English (U.S.)

Copy each block into App Store Connect as is. Limits are App Store
Connect's; the counts were checked when this file was written.

## Name (max 30)

```
PaperDrop — Scan to PDF
```

## Subtitle (max 30)

```
Searchable PDFs from paper
```

## Promotional text (max 170)

```
Scan a page, scan the next, hit Save. PaperDrop turns paper into tiny, searchable PDFs, about 20 KB a page, with text recognition that never leaves your Mac.
```

## Description (max 4000)

```
PaperDrop is a small, native Mac app that turns paper into compact, searchable PDF archives. One big button, no account, no cloud.

Scan a page and it appears as a card. Scan a few more, drag them into order, name the document and click Save: a compressed PDF with a hidden text layer lands in the folder you chose, and Finder shows it to you.

TINY ARCHIVAL PDFS
In Document mode, pages are cleaned up and stored in pure black and white with CCITT G4 compression, the format fax machines perfected: about 20 KB per A4 page at 300 dpi. Scanner-bed shadows along the edges and specks of dust are removed automatically.

SEARCHABLE EVERYWHERE
Apple's on-device text recognition adds an invisible text layer to every page, so your scans are found by Spotlight and searchable in Preview. Nothing is uploaded: recognition runs entirely on your Mac.

KNOWS YOUR PAPER
PaperDrop detects the paper you used and snaps to A4, A5, A6 or Letter, keeping your content where it was on the page. Or force a size: A4, A5, 4×6″, 5×7″, 8×10″ or Letter, in portrait or landscape. Multi-page documents can be padded to one uniform page size.

THE RIGHT MODE FOR EACH PAGE
• Document: crisp black and white, smallest files
• Grayscale: for pencil, faint print and photos
• Color: for anything where color matters

TWO-SIDED DOCUMENTS
Scan the fronts, then the backs, and PaperDrop interleaves them in the right order, whether you use the glass one sheet at a time or a document feeder.

PREVIEW AND TUNE
Take a quick low-resolution preview and adjust brightness, contrast and gamma live before the real scan.

FILE NAMES YOUR WAY
Build file names from a prefix, the date, the time and an optional counter, and choose whether to overwrite or keep both when a name already exists.

WORKS WITH YOUR SCANNER
PaperDrop uses the scanners macOS supports natively:
• AirScan / eSCL network scanners, including many Wi-Fi all-in-one printers
• USB and network scanners with an Image Capture driver
If your scanner shows up in Apple's Image Capture app, or is an AirScan network scanner, PaperDrop can use it.

PRIVATE BY DESIGN
No account, no tracking, no data collected. Your documents go from the scanner straight to the folder you picked.

PaperDrop is available in English and French.

Based on the open-source PaperDrop project by Ben Squire (MIT license).
```

## Keywords (max 100, comma-separated, no spaces)

```
scanner,scan,pdf,ocr,document,paperless,airscan,archive,searchable,duplex,receipt,invoice,flatbed
```

## What's New in This Version (max 4000)

```
First release on the Mac App Store.
```

## URLs

| Field | Value |
|---|---|
| Support URL | https://github.com/thierryH91200/PaperDrop-main |
| Marketing URL (optional) | https://github.com/thierryH91200/PaperDrop-main |
| Privacy Policy URL | https://github.com/thierryH91200/PaperDrop-main/blob/main/PRIVACY.md |

## General information

| Field | Value |
|---|---|
| Primary category | Productivity |
| Secondary category | Utilities |
| Copyright | © 2026 Thierry Hentic |
| Age rating | 4+ (answer "None" to every question) |
| Price | your choice (Free or a tier) |

## App Privacy (privacy "nutrition label")

- Do you or your third-party partners collect data from this app? **No**
- Result shown on the store: **Data Not Collected**

## Export compliance

Already answered in the build (`ITSAppUsesNonExemptEncryption = NO`):
the app uses no encryption beyond what macOS provides.

## App Review — notes for the reviewer

```
PaperDrop needs a document scanner to do its job. It works with any scanner macOS supports natively: AirScan/eSCL network scanners (most Wi-Fi all-in-one printers) and scanners that appear in Apple's Image Capture app.

How to test:
1. Launch PaperDrop. Allow access to the local network when macOS asks; this is how network scanners are found.
2. Pick the scanner in the panel on the right.
3. Place a page on the glass and click the big Scan button. The page appears as a card.
4. Click Save PDF. The first time, choose a folder (the app is sandboxed and only writes where you point it). The PDF opens in Finder; its text is searchable in Preview.

Without a scanner, the app shows "No scanner found". A screen recording of a full scan is available here: <LINK TO VIDEO>

No account or sign-in is required. No data is collected or sent anywhere; text recognition uses Apple's on-device Vision framework.
```

## Screenshots

Mac screenshots must be 16:10, one of 1280×800, 1440×900, 2560×1600 or
2880×1800, between 1 and 10 images. Suggested set:

1. Main window with several scanned page cards and the settings panel
2. A saved PDF open in Preview with text selected (shows the OCR layer)
3. The paper-size and mode settings
4. The file-name builder
5. Two-sided scanning (Recto / Verso buttons)
