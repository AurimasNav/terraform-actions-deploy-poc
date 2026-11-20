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

## The GitHub workflows

Shared by all layouts:

- **Changed root modules** lists the root modules the push changed
  ([scripts/changed-root-modules.sh](scripts/changed-root-modules.sh)).
- Per root module: **Deploy test** and **Plan prod** side by side, then **Deploy prod**,
  which [needs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds)
  only these two. A failed Deploy test keeps only its own root module out of prod.
- The jobs call the [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
  [terraform-apply.yml](.github/workflows/terraform-apply.yml) and
  [terraform-plan.yml](.github/workflows/terraform-plan.yml), which hold the environment,
  the concurrency group and the plan artifact. Their Terraform steps are one
  [composite action](https://docs.github.com/en/actions/tutorials/create-actions/create-a-composite-action),
  [.github/actions/terraform](.github/actions/terraform/action.yml).
- Two environments, `test` and `prod`, for every root module. `prod` has
  [required reviewers](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers),
  so Deploy prod waits for an approval, and only `main` may deploy to it. An approval is
  given per environment and run: it starts every Deploy prod waiting in that run.
- Each root module's deployments to one environment share a
  [concurrency group](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
  A second one waits for the running one, and a newer one replaces one that is still
  waiting, since the newer commit includes its changes (`queue: max` would keep up to 100
  waiting instead). A Deploy prod waiting for approval holds the group: a newer run's
  Deploy prod of that root module waits until the older one is approved or rejected.

### Three layouts

The graph draws the arrows between a called reusable workflow's jobs, except in a
[matrix](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstrategymatrix),
GitHub's only loop, where each root module's jobs are a flat list. It draws every job of
the workflow, run or skipped.

| | Run per root module | Matrix | Explicit jobs |
|---|---|---|---|
| Workflow | [deploy.yml](.github/workflows/deploy.yml), on push | [deploy-matrix.yml](.github/workflows/deploy-matrix.yml), Run workflow | [deploy-explicit.yml](.github/workflows/deploy-explicit.yml), Run workflow |
| New root module | a new folder | a new folder | a 5-line call; **Every root module has a job** ([scripts/check-deploy-jobs.sh](scripts/check-deploy-jobs.sh)) fails without it |
| Arrows | per root module, in its run | between the Deploy test and Plan prod matrices and the Deploy prod matrix | per root module |
| Root modules the push didn't change | no run | not shown | three skipped jobs each in the graph |
| Approvals of `prod` per change | one per root module | one | one for the root modules waiting at the time |
| Deploy prod starts | when its root module's test and plan are done and approved | when every root module's test and plan are done and the change is approved | when its root module's test and plan are done and approved |
| Runs per change | one that starts and links one per root module | one | one |

- **Run per root module:** **Start a run per root module** starts
  [root-module.yml](.github/workflows/root-module.yml) with
  [`workflow_dispatch`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow#triggering-a-workflow-from-a-workflow)
  for each changed root module, with the commit to deploy as an input: a started run takes
  its workflow files from the branch's latest commit, and checks out the given commit.
- **Matrix:** **Ready for prod** lists the root modules whose Deploy test and Plan prod
  succeeded, and the Deploy prod matrix runs only for those.
- **Explicit jobs:** one call of [root-module.yml](.github/workflows/root-module.yml) per
  root module.

## Runs

Measured on 2026-11-20:

| Run | What happened |
|---|---|
| [Run per root module, push changing team-d](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44722601399) | Started one run, [Deploy team-d](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44722626319). |
| [Run per root module, `team-a,team-b,team-c`, `fail_test: team-c`](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44716981069) | Started [team-a](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44717016043), [team-b](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44717020222) and [team-c](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44717023786). team-c's Deploy prod was skipped. Approving team-a's run deployed team-a while team-b's Deploy prod kept waiting for its own approval. |
| [Matrix, `team-a,team-b,team-c`, `fail_test: team-c`](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44722251318) | Ready for prod listed team-a and team-b; team-c got no Deploy prod job. One approval deployed both. |
| [Explicit jobs, `team-a,team-c`, `fail_test: team-c`](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44721412669) | team-a deployed, team-c's Deploy prod was skipped. The graph has 48 job boxes, 42 of them for the 14 skipped root modules. |
| [Started while another run waited for approval](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710269602) | Its Deploy prod jobs stayed pending until the [older run](https://github.com/AurimasNav/terraform-actions-deploy-poc/actions/runs/44710184043) was approved. |

To try it (needs write access, and the repository owner approves `prod`): Actions,
**Deploy**, **Deploy (matrix)** or **Deploy (explicit jobs)**, Run workflow, with `fail_test` set to a root module.

## Limits

- Required reviewers: "If you are on a GitHub Free, GitHub Pro, or GitHub Team plan,
  required reviewers are only available for public repositories"
  ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers)).
  A private repository needs GitHub Enterprise for the approval before prod.
