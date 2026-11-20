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
- There is no matrix or loop over root modules, so a script generates the 48 steps (3 per
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

- [deploy.yml](.github/workflows/deploy.yml): **Changed root modules** lists the root modules
  the push changed ([scripts/changed-root-modules.sh](scripts/changed-root-modules.sh)), and a
  [matrix](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-a-matrix-strategy-with-a-reusable-workflow)
  runs [root-module.yml](.github/workflows/root-module.yml) once per root module.
- root-module.yml: **Deploy test** and **Plan prod** run side by side, and **Deploy prod**
  [needs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds)
  only these two. A failed Deploy test skips only its own root module's Deploy prod.
- Two environments, `test` and `prod`, for every root module. `prod` has
  [required reviewers](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers),
  so Deploy prod waits for an approval, and only `main` may deploy to it.
- An approval is given per environment and run: one approval of `prod` starts every root
  module's Deploy prod that waits in that run. Approving root modules one by one needs a
  prod environment per root module, as in Bitbucket today.
- A new root module is a new folder under `src/`: nothing is generated. A matrix makes
  [up to 256 jobs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstrategymatrix).
- Each root module's deployments to one environment share a
  [concurrency group](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
  A second one waits for the running one, and a newer one replaces one that is still
  waiting, since the newer commit includes its changes (`queue: max` would keep up to 100
  waiting instead). A Deploy prod waiting for approval holds the group: a newer run's
  Deploy prod of that root module waits until the older one is approved or rejected.

```text
GitHub, one run per merge

  team-a:  Deploy test [test] ──┐
           Plan prod ───────────┴──► Deploy prod [prod, approval]
  team-b:  Deploy test [test] ──┐
           Plan prod ───────────┴──► Deploy prod [prod, approval]
  ...
  A failed Deploy test skips only its own module's Deploy prod.
```

## Runs

Measured on 2026-11-20:

| Run | What happened |
|---|---|
| [Push, all 16 root modules](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710184043) | 16 Deploy test and 16 Plan prod succeeded; one approval of `prod` started all 16 Deploy prod. |
| [Run workflow, `fail_test: team-c`](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710269602) | team-c's Deploy test failed and only its Deploy prod was skipped; the other 15 deployed to prod. Started while the first run waited for approval, its Deploy prod jobs stayed pending until that approval. |
| [Push changing only team-b](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710848480) | Only team-b's three jobs ran. |

To try it (needs write access, and the repository owner approves `prod`): Actions,
**Deploy**, Run workflow, with `fail_test` set to a root module.

## Limits

- Required reviewers: "If you are on a GitHub Free, GitHub Pro, or GitHub Team plan,
  required reviewers are only available for public repositories"
  ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers)).
  A private repository needs GitHub Enterprise for the approval before prod.
