## Cycle 2026-08-18T00:39Z (linux_mutable macuahuitl — day-3, fail-loud drain)

**Result: 804-wfcu closed; 801-g9nn delegated as the keystone the last two
landings depend on.**

- 801-g9nn DELEGATED, and its priority changed because of tonight's work rather
  than by decision. 803-su4n put CODE in the index (a stale line number in a
  spec is annoying; in a function someone is about to edit it is a wrong edit)
  and 801-a2by made the index a shared durable volume read-only-mounted into
  every forge. That fork's own closure says it: "801-g9nn's hazard is now live.
  A fingerprint proves an entry describes corpus X, never that X is the
  caller's checkout." The safety property is missing under conditions that now
  exist.
- 804-wfcu COMPLETED. The Linux twin of the macOS uninstall defect: on root,
  `userdel -r` and `rm -rf $SERVICE_HOME` run OUTSIDE the --wipe guard and take
  the packaged service account's model cache with them, after which the script
  printed "Cache preserved." Three reporting changes, none touching the
  deletion — removing a service account's home on uninstall is defensible;
  claiming afterwards that the cache survived is not. Fixture 6/6 -> 7/7.
- I DECLINED TO WRITE THE OBVIOUS TEST, and recorded why. Covering the ROOT
  branch means making a script that runs `userdel -r` believe it is root, and a
  fixture that can be wrong about that can delete a real account on a
  developer's machine. One branch verified by fixture, one reasoned, and the
  gap named in the closure rather than papered over.
- The pair is the interesting part: macOS lost 11.83 GiB and Linux the model
  cache, both reported as preservation, both from ONE sentence written for a
  meaning that had stopped being true. Worth watching wherever an uninstall,
  cleanup or reset path prints reassurance.

STILL THE OPERATOR'S: 809-w2xy, the mirror's Vault GitHub credential denied by
upstream. It blocks every forge-write closure and the destructive e2e, and the
guard forbids the workaround (importing host credentials).
