import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

const actionPath = fileURLToPath(new URL("../action.yml", import.meta.url));
const action = await readFile(actionPath, "utf8");

const stepBlock = (name) => {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const match = new RegExp(
    `    - name: ${escapedName}\\n(?<body>[\\s\\S]*?)(?=\\n    - name:|$)`,
    "u",
  ).exec(action);
  assert.ok(match?.groups?.body, `Missing action step: ${name}`);
  return match.groups.body;
};

test("exposes github.token only to isolated GitHub API steps", () => {
  assert.equal(
    action.match(/\$\{\{ github\.token \}\}/gu)?.length,
    2,
  );

  const resolver = stepBlock("Resolve dispatch pull request");
  assert.match(
    resolver,
    /DISPATCH_GITHUB_TOKEN: \$\{\{ github\.token \}\}/u,
  );
  assert.match(resolver, /working-directory: \$\{\{ github\.action_path \}\}/u);
  assert.match(resolver, /BASH_ENV: ""/u);
  assert.match(resolver, /NODE_OPTIONS: ""/u);
  assert.doesNotMatch(resolver, /run-sst|remove-reconciled|npx sst/u);

  const planner = stepBlock("Plan reconciliation");
  assert.match(planner, /RECONCILE_GITHUB_TOKEN: \$\{\{ github\.token \}\}/u);
  assert.match(planner, /working-directory: \$\{\{ github\.action_path \}\}/u);
  assert.match(planner, /BASH_ENV: ""/u);
  assert.match(planner, /NODE_OPTIONS: ""/u);
  assert.doesNotMatch(planner, /run-sst|remove-reconciled|npx sst/u);
});

test("keeps action-provided tokens out of every SST-bearing step", () => {
  for (const name of [
    "Run SST",
    "Discover reconciliation candidates",
    "Remove reconciled stages",
  ]) {
    const step = stepBlock(name);
    assert.match(step, /DISPATCH_GITHUB_TOKEN: ""/u);
    assert.match(step, /RECONCILE_GITHUB_TOKEN: ""/u);
  }

  for (const name of [
    "Discover reconciliation candidates",
    "Remove reconciled stages",
  ]) {
    const step = stepBlock(name);
    assert.match(step, /GH_TOKEN: ""/u);
    assert.match(step, /GITHUB_TOKEN: ""/u);
  }
});

test("gates token-bearing steps with trusted inputs and event context", () => {
  for (const name of [
    "Plan reconciliation",
    "Remove reconciled stages",
  ]) {
    const step = stepBlock(name);
    assert.match(step, /inputs\.operation == 'reconcile'/u);
    assert.match(step, /github\.event_name == 'schedule'/u);
    assert.match(step, /github\.event_name == 'workflow_dispatch'/u);
    assert.doesNotMatch(step, /steps\.[^.]+\.outputs\.operation/u);
  }
});

test("resolves every manual deploy or remove run before invoking SST", () => {
  const resolver = stepBlock("Resolve dispatch pull request");

  assert.match(resolver, /github\.event_name == 'workflow_dispatch'/u);
  assert.match(resolver, /inputs\.operation == 'auto'/u);
  assert.match(resolver, /inputs\.operation == 'deploy'/u);
  assert.match(resolver, /inputs\.operation == 'remove'/u);
  assert.match(
    resolver,
    /DISPATCH_INPUT_PR_NUMBER: \$\{\{ inputs\.pr-number \}\}/u,
  );
  assert.match(
    resolver,
    /DISPATCH_TARGET_BRANCH: \$\{\{ inputs\.target-branch \}\}/u,
  );
  assert.doesNotMatch(resolver, /steps\.[^.]+\.outputs/u);

  const runSst = stepBlock("Run SST");
  assert.match(runSst, /steps\.dispatch_pr\.outputs\.skip != 'true'/u);
  assert.match(
    runSst,
    /INPUT_PR_NUMBER: \$\{\{ steps\.dispatch_pr\.outputs\.pr_number \|\| inputs\.pr-number \}\}/u,
  );
  assert.match(
    runSst,
    /INPUT_UNLOCK_ON_LOCK: \$\{\{ inputs\.unlock-on-lock \}\}/u,
  );
});

test("requires the trusted default branch for manual cleanup", () => {
  const validation = stepBlock("Validate trusted dispatch ref");

  assert.match(validation, /github\.event_name == 'workflow_dispatch'/u);
  assert.match(validation, /inputs\.operation == 'remove'/u);
  assert.match(validation, /inputs\.operation == 'unlock'/u);
  assert.match(validation, /inputs\.operation == 'reconcile'/u);
  assert.match(validation, /github\.ref_type != 'branch'/u);
  assert.match(
    validation,
    /github\.ref_name != github\.event\.repository\.default_branch/u,
  );
});

test("limits unlock to explicit trusted manual runs", () => {
  const eventValidation = stepBlock("Validate unlock event");
  assert.match(eventValidation, /inputs\.operation == 'unlock'/u);
  assert.match(eventValidation, /github\.event_name != 'workflow_dispatch'/u);

  const runSst = stepBlock("Run SST");
  assert.match(runSst, /inputs\.operation != 'reconcile'/u);
});

test("passes automatic unlock settings to reconciliation removals", () => {
  const removal = stepBlock("Remove reconciled stages");
  assert.match(
    removal,
    /INPUT_UNLOCK_ON_LOCK: \$\{\{ inputs\.unlock-on-lock \}\}/u,
  );
});
