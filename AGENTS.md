# Quill project instructions

## Update the installed app after delivery

This fork includes a manual source updater. Merging code does not update the
installed menu-bar app. After merging app changes into this fork's `main`, run
the updater and verify the installation as part of delivery, unless the user
explicitly asks to leave the installed app unchanged. Documentation-only changes
do not require rebuilding or restarting the app.

1. Verify that `origin` is `https://github.com/Matteo-Muscio/quill-clone.git` and
   that the intended changes are merged into its `main`. The updater installs
   remote `main`, not the current branch or uncommitted working tree.
2. Run `quill update --check`, then `quill update` when an update is needed.
   If `quill` is not on PATH, use the executable from the existing LaunchAgent.
   This Mac's installation is normally
   `"$HOME/Library/Application Support/quill/bin/quill"`.
3. Run `quill update --check` again and confirm it reports up to date. Check
   `launchctl print "gui/$(id -u)/com.digimata.quill"` for the expected executable
   and a running process. Verify the revision in `installed.json` matches the
   intended merged commit and its SHA-256 matches the installed executable.
4. Report merged and installed states separately, including any update failure.

The updater builds in its own cache, runs debug and release tests, verifies the
candidate executable, and requests a cooperative exit only when Quill is idle.
It preserves settings and the existing LaunchAgent plist, retains a backup, and
attempts rollback if restart fails. It requires Git, the Swift toolchain, and an
existing user-owned, writable LaunchAgent executable; do not run it with sudo.

Do not bypass a busy timeout by force-stopping Quill. Finish recording,
transcription, model preparation, or unsaved metadata recovery, then retry.
The default idle timeout is 300 seconds; `--wait <seconds>` changes it and
`--wait 0` requires an already-stopped daemon. Older versions without the
cooperative handoff need a one-time graceful quit after active work finishes.

Logs, the source/build cache, `installed.json`, and `backups/` are under
`~/Library/Application Support/quill/updates/`. Preserve the reported backup
when diagnosing a failed installation. See [README.md](README.md#update-this-fork)
and `Sources/quill/Update.swift` for details.
