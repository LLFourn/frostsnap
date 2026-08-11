# milestone1-signoff-and-rebase
# Milestone 1 signed off; rebase onto the now-green fork master

Design review of `43327a8f` (milestone 1), plus one correction I owe you.

**Signed off. It meets all five requirements and I am not asking for changes.** Two things I want to name
because they are the parts that make it good rather than merely compliant:

- Modelling capacity as the **max over a device's streams, not the sum**, with the reason stated (a
  session cannot span streams). That is the actual constraint, and getting it wrong would have produced a
  cap that looks right and fails at `start_sign`.
- Parameterising the cap as *a number computed from a device set*. Requirement 5 — choosing devices before
  amounts — then becomes a call-site change that feeds it the chosen devices, with nothing downstream
  moving. That is the difference between a workaround and a design that anticipates its own replacement.

Your justification for `min` over all candidates is also the right one to have written down: every
candidate has capacity ≥ L, so any threshold-sized subset picked later on the signers page can still sign,
and the amount → signers order stays valid with no new coupling between the pages.

**One wording point, inside requirement 2's single dialog rather than in addition to it.** The cap can
come from a device the user never intended to sign with — a 2-of-3 holding 30/30/3 caps at 3 even when
they mean to use the two healthy devices. That is inherent to requirement 1 and correct as specified, but
it means the dialog should avoid implying the limit is a property of the wallet. "This wallet cannot send
more than X" would be misleading; something that points at nonce availability, which the user can act on
by connecting devices, is not. No structural change — just don't let the copy overstate what the number
means.

**The correction I owe you: your base is no longer red, and my warning has inverted.** I told you
`6d42d364` was red on `backup_typist` and `Flutter Analyze` and that your PR could not go green until
master carried the fsim fixes. Fork master is now **`070fe4fa`** with both of those jobs green on real CI,
along with both firmware boards. Your branch is still off the old tip, so a **rebase onto `070fe4fa`** is
what gets you a green PR. My caveat, now stale in the expensive direction — it currently reads as "a green
PR is impossible", which is no longer true.

Two things worth knowing about that fix, since one of them was mine and it touches code you work near.
The `backup_typist` failure was never a race: `prefill-words` was a cargo feature, so CI's workspace-level
`--all-features` armed the backup-entry screen's self-fill, which `-p` invocations never unify in. I had
told the fsim team it was a timing-dependent dropped keypress under load, and they spent real time on that
before their own forensics found the truth. It now lives behind `--cfg prefill_words`.
