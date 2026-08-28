# CLA signatures

This branch exists to hold one file: the record of who has agreed to the
Contributor Licence Agreement, written by the CLA check on each pull request.

It is deliberately **not** `main`. The action records a signature by committing
it, and `main` requires every change to arrive through a pull request with a
green build — which a bot committing a signature cannot satisfy. Pointing it at
an unprotected branch of its own keeps both rules intact.

Nothing here is code, and nothing here is merged anywhere.
