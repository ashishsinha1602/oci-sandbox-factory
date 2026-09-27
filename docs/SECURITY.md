# Security review: what Sandbox Factory does in your tenancy

Written for the cloud or security team that is asked to approve the install.
It is deliberately blunt: the strengths, the trust points, and what to require.
Every grant is listed in [PREREQUISITES.md](PREREQUISITES.md); this page explains them.

## What it is, in one paragraph

A self-service portal for temporary cloud environments. Users describe what they
need in a chat; the factory turns that into a Resource Manager stack (Terraform),
builds it inside one compartment, gives the user the links and credentials, and
destroys it when its lifetime (1 to 30 days) ends. Users sign in to an APEX
application; they have no OCI account. The factory runs entirely inside the
tenancy: the portal is an Autonomous Database, the workers are Container
Instances, image builds run in Container Instances, and the assistant calls OCI
Generative AI. Nothing is sent to any service outside Oracle Cloud.

## Where to install it

In a **dedicated compartment with its own budget**, or in a separate sandbox
tenancy. Not in a production compartment. The stack creates a compartment tree
(`<prefix>` with `-control` and `-sandboxes` under it) beneath a parent you choose,
with a budget, quotas and tag defaults on it. Everything the product owns is under
that tree and is removed by destroying the stack.

## Who needs what

| Role | Needs | When |
|---|---|---|
| Installer | tenancy administrator, or a group with the 12 grants in PREREQUISITES.md section 1 | once, to run the stack |
| The factory (its own dynamic groups) | the grants in section 2, scoped to the `<prefix>` tree except for tenancy-wide reads and Generative AI | created by the stack |
| End users | an application login created by the installer | no OCI account, ever |

No human user is granted anything by the install.

## Strengths

- **No API keys.** Workers, the control database and every sandbox database
  authenticate with OCI resource principals; no key file exists anywhere. The
  exceptions are three values the stack passes to the workers as container
  environment variables: the registry auth token they push built images with,
  the control database's ADMIN password, and the portal's first admin password.
  Anyone who can read the worker container's configuration in the console can
  read them, so restrict `read compute-container-family` on the control
  compartment to the operators.
- **Everything is Terraform you can read** before applying: the install stack and
  the sandbox stack are both public. Sandboxes are not generated code; every one
  is the same module with different variables.
- **Scoped grants.** The workers may manage resources only inside the sandboxes
  compartment and Resource Manager stacks inside the control compartment. Code
  inside a sandbox may use Object Storage, Data Flow and Data Catalog inside the
  sandboxes compartment, and Generative AI. The tenancy-wide grants are reads
  (limits, compartments, the Object Storage namespace, repositories) plus
  Generative AI use.
- **Ownership enforced three times.** A user sees only their sandboxes; a
  cross-user destroy or name takeover is refused in the application, again by a
  database trigger, and again by the owner tag on the stack.
- **Cost controls at install time.** A budget with alerts, service quotas on the
  compartment, a per-user cap on live sandboxes, and a lifetime on every sandbox
  enforced by a reaper. Every card has a Destroy button.
- **Secrets users give the factory** (environment variables for their code) never
  reach the assistant; they are a sensitive Terraform variable merged into the
  container or function environment.

## Trust points to raise before approving

1. **The worker image is opaque.** Workers run a bytecode-only image published by
   the vendor, and the install references a floating `worker:release` tag. That
   image holds `manage all-resources` in the sandboxes compartment. Require a
   **pinned version tag** in the stack variable `worker_image` (for example
   `worker:v1.0.7`) and re-review before moving it. A source licence for building
   the image inside your own tenancy is available on request.
2. **Users execute code in your cloud.** A sandbox app, function or Data Flow job
   is the user's own code, running with the sandbox dynamic group's grants above.
   Treat the user population like you would treat people with a CI runner in a
   dev compartment. Budget and quotas bound the cost; `per_sandbox_compartment =
   true` gives each sandbox its own compartment for IAM-level isolation, at the
   cost of slower creates.
3. **Application accounts, not SSO.** Logins are APEX accounts created by the
   installer. SSO through an OCI IAM identity domain is an authentication-scheme
   change in APEX and is not done yet.
4. **Generated passwords live in the control database** and are shown to the
   owner on their card; the worker environment holds the three values above. They are the credentials of the sandbox's own database,
   Airflow or Kafka, not of anything outside the sandbox. Moving them to Vault is
   on the list.
5. **Generative AI sees the conversation.** The chat, the plan and any files the
   user attaches are sent to OCI Generative AI in the install region. That is an
   Oracle service inside the tenancy's data boundary, but it is still a model.
   Users' environment variables are never sent.

## What leaves the tenancy

Nothing, except:

- Public Git URLs the user pastes are fetched by the build container.
- Container images from public registries a user names (for example a Grafana
  image) are pulled by the sandbox's Container Instance.
- The worker image and, for image-heavy documents, Oracle's published ONNX
  embedding model are pulled from Oracle Cloud Infrastructure Registry and
  Object Storage in Oracle's own tenancies.

## Audit and observability

- Every request (create, deploy, destroy, lifetime change) is a row in the
  control database with the requester, the time and the outcome; destroyed
  sandboxes stay visible in History.
- Every resource carries the `<prefix>` tag namespace: owner, sandbox id,
  team, expiry. Cost reports and searches can group on them.
- Each sandbox has its own log group: function invocations and gateway access
  and execution logs.
- Resource Manager keeps the plan and apply log of every stack.

## Removal

Destroy the users' sandboxes, then the stack. The vault is scheduled for
deletion (7 days minimum) and tags are removed slowly; details in
PREREQUISITES.md section 5a. Nothing outside the compartment tree survives.
