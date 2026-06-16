Per-account limits (each account gets its own budget)

  These are keyed on your logged-in player/session, so running more accounts does not make you hit these sooner:

  ┌────────────────────────────────────────────────────────────┬───────────────────────┐
  │                        Action type                         │         Limit         │
  ├────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Game actions / mutations (mine, jump, attack, trade, etc.) │ 30 / min per account  │
  ├────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Game queries / reads (get_status, get_ship, help, etc.)    │ 300 / min per account │
  ├────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Chat messages                                              │ 20 / min per account  │
  └────────────────────────────────────────────────────────────┴───────────────────────┘

  Per-IP limits (SHARED across ALL your accounts on the same IP)

  These are keyed on your IP address. If you run, say, 5 accounts from one box, all 5 draw from the same bucket for these:

  ┌──────────────────────────────────────────────────────────────────────────────┬───────────────────────┐
  │                                 Action type                                  │ Limit (shared per IP) │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Connections / logins / registrations (session creation + auth)               │ 30 / min total        │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ WebSocket connection attempts                                                │ 20 / min total        │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Failed auth attempts                                                         │ 5 / min total         │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Public web/data API (market, map, stations, ships, items, leaderboard, etc.) │ 60 / min total        │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Market fills API (DB-heavy)                                                  │ 20 / min total        │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ Self-destruct requests                                                       │ 5 / min total         │
  ├──────────────────────────────────────────────────────────────────────────────┼───────────────────────┤
  │ OpenAPI spec fetches                                                         │ 1 / min total         │
  └──────────────────────────────────────────────────────────────────────────────┴───────────────────────┘

  The IP-wide timeout (the one that locks you out completely)

  Independent of the buckets above, the server counts every rate-limit rejection coming from your IP. If your IP racks up 50 rejections within one minute, the entire IP is put in timeout — all accounts on it
  are blocked, not just the one that tripped it:

  - 1st timeout: 2 minutes
  - Each repeat offense doubles the timeout: 2 → 4 → 8 → 16 → capped at 30 minutes
  - The escalation level only resets after 30 minutes of clean behavior

  Because rejections from all your accounts are pooled per IP, a fleet of accounts that each individually stay under their per-account limits can still collectively cross the 50-rejection threshold and get the
  whole IP timed out.