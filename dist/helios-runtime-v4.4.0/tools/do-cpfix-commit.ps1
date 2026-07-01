$msg = @"
fix: replace invalid [ordered] and ContainsKey in control_plane_watcher.ps1

Replace [ordered] type checks with [System.Collections.IDictionary] -- [ordered]
is parser syntax, not a valid runtime type for -is checks. Replace .ContainsKey()
with .Contains() -- OrderedDictionary implements IDictionary.Contains, not
ContainsKey. Both fixes resolve err_cp_compare on every PostToolUse invocation.

Add Test-ControlPlaneMutation.ps1 for targeted control-plane diff verification.
"@
git -C "C:\Users\dimas\Desktop\MythosJustAFable" commit -m $msg
