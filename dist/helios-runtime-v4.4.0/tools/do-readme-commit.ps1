$msg = @"
docs: update README to reflect Phase 4.4 architecture

Add runtime file inventory, Phase 4.4 status table, and capability status
section. Document capability classification, segment decomposition, uniform
evidence, control-plane watcher, session continuity, chain linkage, settings
integrity, PostToolUse heartbeat diagnostics, and maintenance rebaseline
corridor. Add truthful status for hashes (implemented), signatures (not
implemented), and file locks (tooling exists, active runtime locking deferred).
"@
git -C "C:\Users\dimas\Desktop\MythosJustAFable" commit -m $msg
