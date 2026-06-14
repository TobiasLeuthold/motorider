# Working in this repository

## Concurrent Claude instances — use worktrees

Multiple Claude instances work on this repo **simultaneously**. To avoid stepping on
each other, never implement a new task directly on `main`. Instead:

1. **Sync `main` first.** Before doing anything, make sure your local `main` is
   up to date:
   ```sh
   git checkout main
   git pull
   ```

2. **Branch out into a new worktree.** Create a dedicated branch and an isolated
   working directory for the task:
   ```sh
   git worktree add ../motorider-<task-name> -b feature/<task-name> main
   ```
   Work inside that new directory (`../motorider-<task-name>`). Each instance gets
   its own checkout, so simultaneous work never collides.

3. **Implement and test on that branch.** Make all changes in the worktree and
   verify them there (build / run / tests) before going further.

   **Use your own emulator — never share one.** Because instances run in
   parallel, two of them must not target the same emulator/device, or installs
   and test runs will collide. Before testing:
   ```sh
   flutter devices          # see what is already running / in use
   ```
   Start a **dedicated** emulator for your task and target it explicitly so you
   only ever touch your own device:
   ```sh
   flutter emulators                          # list available AVDs
   flutter emulators --launch <avd-id>        # boot your own instance
   flutter run -d <device-id>                 # always pin -d to your device
   ```
   If you launch a fresh emulator, shut it down when the task is done so AVDs
   don't pile up.

4. **Auto-merge into `main` as soon as the tests pass.** Do not wait for
   confirmation — if the build and tests are green, re-sync `main` and merge
   right away. If anything fails, stay on the branch and fix it; never merge a
   red branch.
   ```sh
   git checkout main
   git pull
   git merge feature/<task-name>
   ```

5. **Clean up the worktree** once merged:
   ```sh
   git worktree remove ../motorider-<task-name>
   ```

**Do not** commit unfinished or untested work to `main`.

## Reporting back when a task is finished

When a task is done, **always start your final message** with this exact block so
the result can be assessed at a glance:

```
Task successful: yes / no / partially
Issues: <what went wrong, or "none">
Open questions: <anything that needs my decision/attention, or "none">
```

- **Task successful** — `yes` only if implemented, tested green, and merged to
  `main`. `partially` if some of it works but something is incomplete or skipped.
  `no` if it could not be completed.
- **Issues** — list anything that failed, was worked around, or couldn't be
  verified. Write `none` if there's nothing.
- **Open questions** — decisions or ambiguities you need me to resolve. Write
  `none` if there's nothing.

After this block, add any normal detail/explanation as usual.
