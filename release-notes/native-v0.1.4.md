# Inbox Zero Mail Native SDK 0.1.4

- Made Gmail inboxes appear much faster by loading visible inbox threads first and fetching metadata in efficient batch requests.
- Kept existing messages visible during refresh instead of temporarily showing an empty inbox.
- Deferred full message-body downloads until a message is opened, while safely retrying failed batches and pruning stale results.

This release is currently available for Apple Silicon macOS as a signed and notarized DMG.
