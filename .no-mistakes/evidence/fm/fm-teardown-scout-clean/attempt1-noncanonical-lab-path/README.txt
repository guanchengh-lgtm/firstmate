Discarded setup attempt: the lab home and TREEHOUSE_ROOT used the non-canonical /var/folders path while firstmate canonicalized to /private/var.
Treehouse recorded both path spellings for one slot, flagged its state as corrupt, and took its recovery path (moving untracked files to a backup).
That is a lab artifact, not product behavior. The scenarios were re-driven in a lab with canonical paths.
