# Terraform deploys per root module: Bitbucket Pipelines vs GitHub Actions

A proof of concept of how a Terraform monorepo's deploy pipeline from Bitbucket Pipelines
looks in GitHub Actions. The repository has 16 root modules (`src/*`), each deployed to a
`test` and a `prod` workspace. The jobs only echo what they would run.

## The Bitbucket pipeline

On a merge to `main`, for each changed root module: **Deploy test** and **Plan prod** run
side by side, then **Deploy prod** is started by hand after reviewing the plan. Bitbucket's
rules shape the pipeline:

- A deployment environment can be used by only one step per pipeline: Bitbucket
  [rejects the pipeline otherwise](https://community.atlassian.com/t5/Bitbucket-questions/The-deployment-environment-test-in-your-bitbucket-pipelines-yml/qaq-p/1250596)
  (stages share one environment between steps, but [a stage can't include parallel steps](https://support.atlassian.com/bitbucket-cloud/docs/stage-options/)).
  So every root module has its own environments, `<module>-test` and `<module>-prod`:
  32 environments for 16 root modules, created by a script and deleted by hand.
- [All environments in a parallel step set must be of the same type](https://support.atlassian.com/bitbucket-cloud/docs/parallel-step-options/),
  so the Deploy prod steps form a second parallel group after the Deploy test group.
- A step starts only when the whole previous group succeeded: one root module's failed
  Deploy test blocks every root module's Deploy prod ([BCLOUD-19908](https://jira.atlassian.com/browse/BCLOUD-19908)).
- There is no loop over root modules, so a script generates the 48 steps (3 per
  root module) into `bitbucket-pipelines.yml`, and a check fails pull requests that leave it out
  of date. A pipeline holds [at most 100 steps](https://support.atlassian.com/bitbucket-cloud/docs/limitations-of-bitbucket-pipelines/):
  about 33 root modules.

```text
Bitbucket, one pipeline per merge

  group 1 (parallel)                         group 2 (parallel, manual steps)
  team-a: Deploy test   [team-a-test]        team-a: Deploy prod   [team-a-prod]
  team-a: Plan prod                     ──►  team-b: Deploy prod   [team-b-prod]
  team-b: Deploy test   [team-b-test]        ...
  team-b: Plan prod
  ...
  Any failed step in group 1 blocks all of group 2.
```

## The GitHub workflow

[deploy.yml](.github/workflows/deploy.yml) runs on a push to `main`:

- **Changed root modules** lists the root modules the push changed
  ([scripts/changed-root-modules.sh](scripts/changed-root-modules.sh)).
- Per root module, three top-level jobs: **Deploy test** and **Plan prod** side by side, and
  **Deploy prod**, which [needs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds)
  only these two. A failed Deploy test skips only its own root module's Deploy prod, and
  the jobs of root modules the push didn't change show as skipped.
- Each job is a short call of a [reusable workflow](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows),
  [terraform-apply.yml](.github/workflows/terraform-apply.yml) or
  [terraform-plan.yml](.github/workflows/terraform-plan.yml), which hold the environment,
  the concurrency group and the plan artifact. Their Terraform steps are one
  [composite action](https://docs.github.com/en/actions/tutorials/create-actions/create-a-composite-action),
  [.github/actions/terraform](.github/actions/terraform/action.yml).
- Two environments, `test` and `prod`, for every root module. `prod` has
  [required reviewers](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers),
  so Deploy prod waits for an approval, and only `main` may deploy to it.
- An approval is given per environment and run: one approval of `prod` starts every root
  module's Deploy prod that waits in that run. Approving root modules one by one needs a
  prod environment per root module, as in Bitbucket today.
- Each root module's deployments to one environment share a
  [concurrency group](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
  A second one waits for the running one, and a newer one replaces one that is still
  waiting, since the newer commit includes its changes (`queue: max` would keep up to 100
  waiting instead). A Deploy prod waiting for approval holds the group: a newer run's
  Deploy prod of that root module waits until the older one is approved or rejected.

```text
GitHub, one run per merge

  Changed root modules ─┬─► team-a: Deploy test [test] ──┐
                        ├─► team-a: Plan prod ───────────┴──► team-a: Deploy prod [prod, approval]
                        ├─► team-b: Deploy test [test] ──┐
                        ├─► team-b: Plan prod ───────────┴──► team-b: Deploy prod [prod, approval]
                        └─► ...
  A failed Deploy test skips only its own module's Deploy prod.
```

### Explicit jobs or a matrix

GitHub draws dependency arrows only between a workflow's top-level jobs, and its only loop,
[`strategy.matrix`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstrategymatrix),
makes one top-level job. So:

- **Explicit jobs** ([deploy.yml](.github/workflows/deploy.yml)): the graph draws each root
  module's chain. A new root module needs its three jobs, 17 lines;
  **Every root module has jobs** ([scripts/check-deploy-jobs.sh](scripts/check-deploy-jobs.sh))
  fails when a folder under `src/` has none.
- **Matrix** ([deploy-matrix.yml](.github/workflows/deploy-matrix.yml), Run workflow only):
  runs [root-module.yml](.github/workflows/root-module.yml), the same three jobs, once per
  changed root module. A new root module is only a new folder, but the graph shows each
  root module's jobs as a flat list, without the arrows. The dependency still holds.

## Runs

Measured on 2026-11-20:

| Run | What happened |
|---|---|
| [Explicit jobs, `fail_test: team-c`](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44715164243) | team-c's Deploy test failed and only its Deploy prod was skipped. One approval of `prod` started the other 15 Deploy prod. |
| [Push changing only team-b](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44715613020) | Only team-b's three jobs ran; the other root modules' jobs show as skipped. |
| [Matrix, `team-a,team-c`, `fail_test: team-c`](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44715391454) | team-a deployed to prod; team-c's Deploy prod was skipped. |
| [Started while another run waited for approval](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710269602) | Its Deploy prod jobs stayed pending until the [older run](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710184043) was approved. |

To try it (needs write access, and the repository owner approves `prod`): Actions,
**Deploy** or **Deploy (matrix)**, Run workflow, with `fail_test` set to a root module.

## Limits

- Required reviewers: "If you are on a GitHub Free, GitHub Pro, or GitHub Team plan,
  required reviewers are only available for public repositories"
  ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers)).
  A private repository needs GitHub Enterprise for the approval before prod.
