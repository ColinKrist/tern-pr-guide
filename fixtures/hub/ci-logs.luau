--!strict
-- What `gh` and `bk` print for the sample board's failing checks, by the command that printed it. The sample block's
-- runner answers from here, so the fixes page runs the real CI modules on recorded output.
-- The Actions log is recorded from jubbydev/tern-pr-guide-hub-smoke run 37983327811 (`gh run view --log-failed`,
-- 2026-10-12). The Buildkite output is SYNTHETIC, hand-written in the shape `bk` 3 prints (cmd/build/recursive.go
-- for --recursive --json; terminal-to-llm's digest for `bk job log --agent`), because no Buildkite org is reachable here.
local M = {}

M.actions = [=[
fail	UNKNOWN STEP	﻿2026-10-10T08:46:49.7946580Z Current runner version: '2.337.0'
fail	UNKNOWN STEP	2026-10-10T08:46:49.7973914Z ##[group]Runner Image Provisioner
fail	UNKNOWN STEP	2026-10-10T08:46:49.7975003Z Hosted Compute Agent
fail	UNKNOWN STEP	2026-10-10T08:46:49.7975670Z Version: 20261002.596
fail	UNKNOWN STEP	2026-10-10T08:46:49.7976378Z Commit: c3d12f3313a95f25162a1503be624f3b0617f8c0
fail	UNKNOWN STEP	2026-10-10T08:46:49.7977234Z Build Date: 2026-10-02T22:28:27Z
fail	UNKNOWN STEP	2026-10-10T08:46:49.7977979Z Worker ID: {a9a04379-34e4-42e4-b87b-d8f4970eb3ee}
fail	UNKNOWN STEP	2026-10-10T08:46:49.7978802Z Region: southcentralus
fail	UNKNOWN STEP	2026-10-10T08:46:49.7979898Z Cloud: Azure
fail	UNKNOWN STEP	2026-10-10T08:46:49.7980493Z ##[endgroup]
fail	UNKNOWN STEP	2026-10-10T08:46:49.7982193Z ##[group]Operating System
fail	UNKNOWN STEP	2026-10-10T08:46:49.7982867Z Ubuntu
fail	UNKNOWN STEP	2026-10-10T08:46:49.7983422Z 24.04.5
fail	UNKNOWN STEP	2026-10-10T08:46:49.7984447Z LTS
fail	UNKNOWN STEP	2026-10-10T08:46:49.7984987Z ##[endgroup]
fail	UNKNOWN STEP	2026-10-10T08:46:49.7985694Z ##[group]Runner Image
fail	UNKNOWN STEP	2026-10-10T08:46:49.7986332Z Image: ubuntu-24.04
fail	UNKNOWN STEP	2026-10-10T08:46:49.7986932Z Version: 20261004.327.1
fail	UNKNOWN STEP	2026-10-10T08:46:49.7988303Z Included Software: https://github.com/actions/runner-images/blob/ubuntu24/20261004.327/images/ubuntu/Ubuntu2404-Readme.md
fail	UNKNOWN STEP	2026-10-10T08:46:49.7990425Z Image Release: https://github.com/actions/runner-images/releases/tag/ubuntu24%2F20261004.327
fail	UNKNOWN STEP	2026-10-10T08:46:49.7991477Z ##[endgroup]
fail	UNKNOWN STEP	2026-10-10T08:46:49.7994795Z ##[group]GITHUB_TOKEN Permissions
fail	UNKNOWN STEP	2026-10-10T08:46:49.7997268Z Actions: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.7998013Z ArtifactMetadata: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.7998715Z Attestations: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.7999547Z Checks: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8000196Z CodeQuality: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8000782Z Contents: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8001351Z CopilotRequests: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8002021Z Deployments: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8002628Z Discussions: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8003233Z Drives: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8003801Z Issues: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8004469Z Metadata: read
fail	UNKNOWN STEP	2026-10-10T08:46:49.8005085Z Models: read
fail	UNKNOWN STEP	2026-10-10T08:46:49.8005794Z Packages: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8006551Z Pages: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8007181Z PullRequests: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8007809Z RepositoryProjects: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8008527Z SecurityEvents: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8009154Z Statuses: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8009951Z VulnerabilityAlerts: read
fail	UNKNOWN STEP	2026-10-10T08:46:49.8010625Z ##[endgroup]
fail	UNKNOWN STEP	2026-10-10T08:46:49.8012729Z Secret source: Actions
fail	UNKNOWN STEP	2026-10-10T08:46:49.8013856Z Cache mode: write
fail	UNKNOWN STEP	2026-10-10T08:46:49.8014548Z Prepare workflow directory
fail	UNKNOWN STEP	2026-10-10T08:46:49.8347460Z Prepare all required actions
fail	UNKNOWN STEP	2026-10-10T08:46:49.8451584Z Complete job name: fail
fail	UNKNOWN STEP	2026-10-10T08:46:49.9205423Z ##[group]Run exit 1
fail	UNKNOWN STEP	2026-10-10T08:46:49.9206159Z [36;1mexit 1[0m
fail	UNKNOWN STEP	2026-10-10T08:46:50.0053973Z shell: /usr/bin/bash -e {0}
fail	UNKNOWN STEP	2026-10-10T08:46:50.0055009Z ##[endgroup]
fail	UNKNOWN STEP	2026-10-10T08:46:50.0459932Z ##[error]Process completed with exit code 1.
fail	UNKNOWN STEP	2026-10-10T08:46:50.0703541Z Cleaning up orphan processes
]=]

M.buildkiteFailures = [=[
{
  "root_build": "acme/web/429",
  "complete": true,
  "failures": [
    {
      "build": "acme/web/429",
      "id": "0190046e-e199-453b-a302-a21a4d649d31",
      "name": ":jest: Unit tests",
      "state": "failed",
      "web_url": "https://buildkite.com/acme/web/builds/429#0190046e-e199-453b-a302-a21a4d649d31",
      "log_url": "https://api.buildkite.com/v2/organizations/acme/pipelines/web/builds/429/jobs/0190046e-e199-453b-a302-a21a4d649d31/log",
      "raw_log_url": "https://api.buildkite.com/v2/organizations/acme/pipelines/web/builds/429/jobs/0190046e-e199-453b-a302-a21a4d649d31/log.txt",
      "trigger_path": []
    }
  ],
  "issues": []
}
]=]

M.buildkiteLog = [=[
~~~ Running commands
$ yarn jest --ci
[… 212 lines omitted …]
+++ :jest: Unit tests
 FAIL  src/cart/reprice.test.ts
  ● reprice › keeps the promo code after a shipping change

    expect(received).toBe(expected) // Object.is equality

    Expected: "SAVE10"
    Received: undefined

      40 |   const next = reprice(cart, { shipping: "express" });
      41 |
    > 42 |   expect(next.promo).toBe("SAVE10");
         |                      ^
      43 | });

      at Object.<anonymous> (src/cart/reprice.test.ts:42:22)
      at reprice (/workdir/src/cart/reprice.ts:57:10)

Tests: 1 failed, 211 passed, 212 total
🚨 Error: The command exited with status 1
]=]

M.outputs = {
	["gh run view 902 --repo acme/web --log-failed --job 1"] = M.actions,
	["bk build view acme/web/429 --recursive --json"] = M.buildkiteFailures,
	["bk job log 0190046e-e199-453b-a302-a21a4d649d31 --agent --max-tokens 1500"] = M.buildkiteLog,
}

return M
