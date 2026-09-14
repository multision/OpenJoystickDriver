# Reconcile A GitHub Release

Use this procedure after the release commit and changelog are complete. The
GitHub workflow creates the tag, signs and notarizes the app, uploads the DMG,
and asks GitHub to generate release notes. Publication is a separate authorized
action; do not infer permission to publish from this procedure.

## Before Publication

1. Check out the exact release commit and run `just check`.
2. Confirm `git status --short` is empty and run `git diff --check`.
3. Generate or preview GitHub's release notes for the intended tag and previous
   tag.
4. Reconcile closed or unmerged contributions that are integrated in the
   release but omitted by GitHub. Confirm each contribution in source, tests,
   the changelog, or recorded hardware evidence.

## Reconcile The Body

Preserve GitHub's standard sections and order:

1. `What's Changed` lists each credited item, author, and hosted link.
2. `New Contributors` lists only accounts making their first credited
   contribution. Check earlier releases before adding an account.
3. `Full Changelog` compares the previous release tag with the new tag.

Use a UTF-8 body file rather than shell interpolation. Read the hosted release
back immediately after editing and compare every line with the intended body.

## Verify Before Closing Items

Verify all of these against the hosted release:

- the tag resolves to the intended commit;
- the release is published, not a draft;
- a prerelease tag is marked as a prerelease;
- the expected DMG exists and its asset state is uploaded;
- the complete body contains the contribution and contributor links;
- the Full Changelog range starts at the previous release and ends at the new
  release.

Only then post item-specific comments describing the implemented behavior and
the remaining hardware procedure. Close issues or unmerged pull requests only
when their audit classification says the published release is the closure
gate. Leave hardware-confirmation items open.
