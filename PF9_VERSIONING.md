# PF9 package versioning

Packages built from this repository carry a PF9 revision, `PF9_REVISION`, a single
positive integer that starts at 1.

* It is part of the package version: `2:<upstream>-pf9.<revision>+<os>` for debs
  (for example `2:3.3.6-pf9.1+u22`) and `2:<upstream>.pf9.<revision>-<release>` for RPMs
  (for example `2:3.3.6.pf9.1-1.el10`).
* It is the only signal that a build differs from what is installed. The same revision
  means "unchanged, do not upgrade"; a higher revision means "reinstall".
* Epoch 2 starts this scheme; it sorts above every earlier pf9 build (epoch 1) and above
  the distribution packages.

**Any change that must reach hosts has to increment `PF9_REVISION` in the same change.**
`build-aux/pf9-check-revision.sh` (run by the `pf9-revision-check` workflow on pull
requests) fails when packaged source changed and the counter did not.
