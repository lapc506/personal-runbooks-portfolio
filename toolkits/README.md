# Toolkits — diagnostic tools and skeleton runbooks

This directory is a **second tier** of content, separate from the empirically-validated runbooks at the top-level OS directories (`linux/`, `macos/`, etc.).

## The two tiers

| | **Tier 1: Runbooks** (`linux/`, `macos/`, ...) | **Tier 2: Toolkits** (this directory) |
|---|---|---|
| **Voice** | "I got bit by X, here's the journey and the fix" | "X is a known failure category on this class of hardware/software. Here's how to detect it early." |
| **Validation** | Empirically applied on a real machine whose specific hardware + driver + distro + kernel is documented inline. | Built from upstream documentation, community reports, and vendor docs. Not yet tested on the author's machine because the bug hasn't hit yet. |
| **Content** | Full diagnostic story, failed attempts, root cause, fix script, verification, rollback, debugging lessons. | Diagnostic scripts, baseline captures, hypothesis lists, pointers to upstream issues. No "this worked" claims for fixes that haven't been validated. |
| **When to promote** | — | When a hypothesis in a toolkit gets validated by actually hitting the bug and applying a fix, the content moves into Tier 1 with the journey captured. |

## Why the separation exists

The Tier 1 runbooks have a distinctive voice: "on the test machine Attempt 1 did NOT work because...", "I initially suspected GPU drivers, but `nfsnobody` in the sandbox revealed the real cause was AppArmor". That voice is only possible when the author has actually walked the debugging path.

If every "these are the commands that probably fix X" blog post got upgraded into a runbook, the portfolio would lose its signal — it'd become indistinguishable from a generic wiki. Tier 2 gives a home to proactive/preventive content (diagnostics, baselines, hypothesis lists) without diluting the empirical claim of Tier 1.

## What lives here

- **Diagnostic toolkits** — scripts that capture a machine's current state in a specific domain (GPU, network, audio, power) so that when something breaks, you have a "known-good" snapshot to diff against. Useful even before any bug exists.
- **Skeleton runbooks** — documents for known-bug categories where the symptoms and first-line diagnostics are well-understood (from upstream docs, vendor advisories, common StackOverflow threads), but the author hasn't yet applied a fix on their own machine. Skeleton runbooks are explicit about this: they mark their fix sections with "⚠ NOT YET EMPIRICALLY VALIDATED" and cite the sources the guidance comes from.

## Index

- [`NVIDIA_Intel_Hybrid_Graphics_Baseline`](./NVIDIA_Intel_Hybrid_Graphics_Baseline) — baseline capture + regression detector for hybrid Intel + NVIDIA Optimus laptops under Wayland. Also hosts the hypothesis list of known Wayland/Optimus problem categories (cursor desync, runtime PM drain, HDMI routing, suspend/resume VRAM save-restore, PipeWire screen-capture GPU confusion, module-load ordering, fractional scaling at mixed DPI) with first-line diagnostics for each.

## Promotion path (Tier 2 → Tier 1)

When a skeleton runbook's hypothesis gets empirically validated:

1. Hit the bug on the actual machine.
2. Walk through the debugging journey — confirm the symptoms match the skeleton's predictions, or discover they don't.
3. Apply the candidate fix. Did it work? Fully? Partially?
4. If the fix worked, copy the skeleton into the appropriate Tier 1 directory (`linux/<Descriptive_Name>/`), then **rewrite it in the first-person empirical voice**:
   - Add the actual error output seen
   - Add the Attempts-that-failed story if any
   - Rewrite the fix section as "what actually happened on the test machine" instead of "what upstream says"
   - Add debugging lessons from the real experience
5. Leave the skeleton in place or update it to point at the new Tier 1 runbook — the skeleton is still useful to people who haven't hit the bug yet and want preventive diagnostics.

The goal is that Tier 2 acts as a staging area for Tier 1, with a clear epistemic status in the meantime.
