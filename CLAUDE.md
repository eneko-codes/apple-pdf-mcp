# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S FILES ARE NOT YOURS TO CHANGE

**It is FORBIDDEN to create, modify, move, trash or tag any file outside this repository.**
This rule outranks every other instruction in this file. It applies to every agent and every
session, with no "just this once" and no putting-it-back-afterwards. Only the owner can lift
it, and only as described under **Live data** below.

This server exists to bound what a program may touch. An agent that reaches around it —
opening a file with `PDFKit` directly, shelling out, or "just checking" something in the
home directory — has defeated the only thing the repository is for.

Never:

- read, write or otherwise touch any real path outside this repository, by any route,
  including plain shell commands;
- run a tool against a real path to test it on your own initiative: `PathScopeTests`
  covers every case with a modelled scope, and a real path needs the owner's go-ahead
  under the live-data rule below;
- widen `readRoots` or `writeRoots` in a committed default;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A temporary directory the agent created
itself — under `$TMPDIR`, never under `~` — may be written to and read from freely, provided
it is deleted in the same session.

**Fixtures first, always.** The store double in `PathScopeTests` **throws from every method
except `canonicalise`**. That is deliberate: a scope test that accidentally reached a real
file must fail loudly rather than quietly pass. Keep it that way.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests model the scope; they never touch a real file |
| `initialize`, `tools/list` over stdio | Protocol only; no path is resolved |
| `ls`, `stat` inside this repository | Read-only, in scope |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against real files remains the **owner's** job, by hand, with MCP
Inspector.

## Live data is the owner's call, not yours

**Tests run against fakes** — the modelled scope and `StubStore`, never a real file. A suite
exists to catch breaking changes and does not need the owner's documents to do that, so never
reach for a real path out of convenience.

**Debugging against a real file is sometimes the only way to see a real bug, and it is
allowed — but the owner decides it, never you.** Ask in chat as an explicit choice they can
pick, not a remark inside a longer message, saying exactly what you will run, exactly which
file it would touch, and what it would create, change or delete and whether that is undoable.
A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, work on
a copy under `$TMPDIR` — the exception above exists for exactly this; failing that, ask the
owner to put a throwaway file there for you. Writing to a file the owner made is the last
resort, has to have been named in the ask, and has to be undoable.

## Language

**Everything in this repository is written in English, without exception** — code,
comments, tool descriptions, error messages, documentation, tests, demo assets and commit
messages. No localised UI strings, and no examples drawn from documents in another
language: an example that needs translating to be understood does not belong here.

**No personal data anywhere, ever.** Not in demo images, not in test fixtures, not in
sample output. Use placeholder identities — `user`, `ACME Ltd`, `REF-000123`, and
`/Users/user/…` for paths. Real names, real ID numbers and real personal documents are
leaks waiting to be committed, and a public repository does not forget: a blob stays
fetchable by its hash after a force-push, so the only true fix is deleting the repository.

**A file leaks more than its contents.** Check what is *inside* an image before committing
it, not just what it depicts: `sips -g all` on a screenshot here reported an ICC profile
naming the display model it was captured on. Strip metadata to something generic before
publishing — `sips -d profile` then `sips -m <sRGB profile>` — and scan with `strings`
for device names, usernames and paths.

## What this is

A local MCP server (Swift 6, stdio transport) for reading **and writing** PDFs through
`PDFKit`: text extraction, outline and document metadata, page assembly, annotations, form
fields, search, encryption/permissions, redaction and page rendering. No Finder, no Apple
events, no network.

**Policy history, because it contradicts what git blame will show:** this server was
originally built read-only by deliberate design — see the note below — and its own
documentation once said "no write of any kind and never will." The owner reversed that
decision explicitly (2026-09-07): the goal is for this server to edit a PDF, not
only extract text from one it cannot touch. That
reversal is why the write-scope machinery described below exists; it is not scope creep
that slipped past review.

**This package requires macOS 26** (`platforms: [.macOS("26.0")]`). `.v26` exists as a
`PackageDescription` case only from `_PackageDescription 6.2`; this package declares
`swift-tools-version: 6.0`, so the string form is required here.

**This server reads and edits PDFs. It does not read pixels.** Text recognition is a
different concern and has no place in this repository — do not add it, and do not describe a
scanned PDF as something this server can read.

## Apple frameworks

[PDFKit](https://developer.apple.com/documentation/pdfkit) is the whole of the document work: `PDFDocument`, `PDFPage`, `PDFAnnotation` (with `PDFAnnotationSubtype`/`PDFAnnotationWidgetSubtype`), `PDFSelection`, `PDFOutline`, `PDFDestination`, `PDFDocumentAttribute`, `PDFDocumentWriteOption`, `PDFAccessPermissions`. [Core Graphics](https://developer.apple.com/documentation/coregraphics) rasterises a page; [AppKit](https://developer.apple.com/documentation/appkit) `NSBitmapImageRep` turns it into PNG; [FileManager](https://developer.apple.com/documentation/foundation/filemanager) does the scope checks and the writing.

## Native surface not used

PDFKit is larger than what is exposed. Check here before proposing a tool.

- The `PDFAction` family — `PDFActionGoTo`, `PDFActionURL`, `PDFActionNamed`, `PDFActionResetForm`, `PDFActionRemoteGoTo`. Link targets and form actions are neither read nor written.
- `PDFBorder`, `PDFAppearanceCharacteristics`, and every deprecated per-type annotation subclass — annotations are built through `PDFAnnotation(bounds:forType:withProperties:)`.
- The whole view layer: `PDFView`, `PDFThumbnailView`, `PDFPageOverlayViewProvider`.
- There is **no** public PDFKit API for a CMS/PKCS7 signature. That is a framework limit, not an omission, and no tool here may imply otherwise.
- Vision is not linked at all.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-pdf-mcp | grep UsageDescription
```

## Architecture

`Sources/PDFMCPCore` holds everything; `Sources/apple-pdf-mcp/main.swift` is a launcher
that exists only because a Swift executable target cannot be imported by a test target.

**`PathScope` is the point of the repository.** One small file with two exported
operations: turn a string the model wrote into a `ScopedPath` (read) or a `WriteScopedPath`
(write destination), or refuse.

**`ScopedPath` and `WriteScopedPath`'s initialisers are `fileprivate` to `PathScope.swift`.**
No other code in the module can mint either, so a store method that takes a path can only
ever be handed a path that came through the matching allow-list — and, because they are
distinct types, a write handler cannot accidentally satisfy its output-path parameter with
a merely-read-scoped path. Forgetting either check is a **compile error**, not an escape —
and the tests cannot skip past the guard either. Do not relax that access level, and do not
add a second way to construct either type.

## Invariants worth protecting

- **Canonicalise first, then compare. The order is not negotiable.** Comparing the raw
  string would let `~/Documents/../../../etc` and a symlink pointing out of the tree both
  pass a prefix test while landing somewhere else entirely.
- **The roots are canonicalised too.** `/tmp` is a symlink to `/private/tmp`, so a root
  compared raw would reject every path that resolved through it.
- **Containment is by path component, not by string prefix.** `Documents-private` is not
  inside `Documents`.
- **Every mutating tool writes to a new path; none overwrite their input.** `output_path`
  is required and always resolved through `resolveForWrite`/`writeRoots`, never through the
  read-only `readRoots`. Nothing stops a caller passing the same path back in on purpose,
  but no tool does that implicitly — there is no in-place mode.
- **A password-protected PDF is refused unless a password is given**, not silently returned
  empty. `PDFDocument` reports a locked document's page count as 0, which reads as an empty
  PDF unless the lock is checked for first.
- **A PDF with no text layer is reported, not guessed at.** `hasTextLayer` is what tells `pdf_read` to say a
  document is a scan instead of returning empty pages.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**
- **No signature tool exists, and none should fake one.** Public PDFKit has no API for a
  real CMS/PKCS7 signature, so `pdf_fill_form` skips a signature field outright rather than
  writing a placeholder value into it. If a signature-stamp tool is ever added, it must
  never claim or imply it produced a legally binding signature — only a real one does that.
- **Redaction rasterizes the affected page; it does not merely draw over it.** Burning an
  opaque annotation into a page (`burnInAnnotationsOption`) leaves the original text
  operators intact underneath — that is not redaction, it is a solid-color sticker, and
  treating it as the former would be a real information leak for a user handling legal
  documents. `pdf_redact_pages` must rasterize the whole affected page to an image after
  painting the box, discarding the original content stream outright.

## `read_roots`/`write_roots` are the one settings exception

The general rule is plug-and-play: constants in code, with only the per-tool
allow/ask/prohibit switch left as a control. This server is the deliberate exception.
`read_roots` and `write_roots` are not a preference to default away — together they are the security
boundary itself. Do not remove either setting for the sake of consistency;
that inconsistency is intentional. `write_roots` defaults to empty like
`read_roots` always has: unconfigured means unreachable, never "falls back to read_roots."

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-pdf-mcp.mcpb`. The
manifest's `tools` array creates the per-tool switches in Claude Desktop and is read
before the server has ever run.

**Apple silicon only, deliberately.** `pack.sh` runs a plain `swift build -c release` — no
`--arch` flags. A universal build doubles the bundle for an architecture macOS 26 no longer
ships on. Do not add `--arch x86_64` back.

**No binary is ever published — no Releases, no attached `.mcpb`, and do not add a workflow
that makes one.** Two reasons, and the first is the owner's call: a real signature embeds the
signer's identity, readable by anyone with `codesign -d -r-`, and this repository is
deliberately pseudonymous. The second stands on its own: TCC keys a folder grant to the
signature, so a binary signed by someone else gives the installer a permission they cannot
renew, and an ad-hoc one re-prompts after every update. Building locally with one's own
identity is the only route that works properly. CI's artifact is a build check, labelled as
such, and is not a distribution channel.

**`pack.sh` uses only Apple tooling** — `swift`, `codesign`, `otool`, `zip`, `unzip`,
`plutil`. Not Homebrew's `python3`, and not Anthropic's `mcpb` CLI, which needs Node; an
`.mcpb` is a zip with `manifest.json` at its root. Note `plutil -lint` is the wrong flag for
the manifest: it lints property lists and rejects JSON outright. `plutil -convert json -o
/dev/null` is the check that works.

`read_roots` and `write_roots` are both `multiple: true` directory settings, passed as
`--read-roots …` and `--write-roots …` respectively.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject**. The embedded `Resources/Info.plist` declares the folder usage
descriptions — Desktop, Documents, Downloads, removable and network volumes — without
which macOS denies access **without ever prompting**. Those descriptions now cover both
reading and writing PDFs in the same folders; macOS does not distinguish read from write
access at the TCC layer for these folder categories, so one usage-description string per
folder still suffices.

Those prompts are per-folder and appear the first time a path inside one is touched. A
root that is configured but never reached will not prompt, which is why `pdf_status`
probes every root and reports what it found.

**A linker-signed binary gets no TCC prompt at all.** `pack.sh` re-signs and prints the
designated requirement; an empty line there means the build is broken in a way nothing
else will show.
