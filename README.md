# flies-for-a-cause
The Flies for a Cause Application is a web UI and API for handling auctions on social media.

## Branching Strategy

This repository uses two long-lived branches, each tied to a deployed environment:

- **`main`** — production. Deploying to `https://flies-for-a-cause.org` / `https://api.flies-for-a-cause.org` is triggered by merges to this branch.
- **`develop`** — development. Deploying to `https://dev.flies-for-a-cause.org` / `https://dev-api.flies-for-a-cause.org` is triggered by merges to this branch.

Workflow:

1. Create a feature/fix branch off `develop` (e.g., `feature/event-crud`, `fix/auction-sort`).
2. Open a pull request back into `develop`. Merging deploys to the dev environment.
3. Once changes are verified in dev, open a pull request from `develop` into `main` to promote them to production. Production deploys require an approval gate.

`main` is a protected branch: direct pushes are disabled and changes must land via a reviewed pull request.
