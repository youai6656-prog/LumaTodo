#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
probe_dir="$(mktemp -d)"
trap 'rm -rf -- "$probe_dir"' EXIT
swiftc -swift-version 6 -module-name LumaTodo -target "$(uname -m)-apple-macosx26.0" \
    Sources/LumaTodo/App/Preferences.swift Sources/LumaTodo/Models/TaskItem.swift Sources/LumaTodo/Models/Attachment.swift \
    Sources/LumaTodo/Services/TaskStore.swift Sources/LumaTodo/Services/AttachmentManager.swift \
    Sources/LumaTodo/Services/FileStorageService.swift Sources/LumaTodo/Utilities/OccurrenceCalendar.swift \
    Tests/PersistenceProbe.swift -o "$probe_dir/probe"

mkdir "$probe_dir/fresh" "$probe_dir/migration"
for mode in write read delete-appended delete empty; do
    "$probe_dir/probe" "$mode" "$probe_dir/fresh/Tasks.store"
done
printf 'PASS: SwiftData task, reminders, and snooze survived restart, with a new task and attachment created and deleted on a reopened store.\n'

# The checked-in store was created by the 1.1 TaskStore using synthetic tasks only.
cp Tests/Fixtures/LumaTodo-1.1.store "$probe_dir/migration/Tasks.store"
for mode in migrate-and-attach reopen-and-remove delete-with-attachments verify-deletion; do
    "$probe_dir/probe" "$mode" "$probe_dir/migration/Tasks.store"
done
printf 'PASS: 1.1 migration, independent attachment copies, cancel, reopening, and deletion across four processes.\n'
