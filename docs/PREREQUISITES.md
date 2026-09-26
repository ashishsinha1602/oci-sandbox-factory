# Installing Sandbox Factory in an OCI tenancy

One Resource Manager stack (`foundation/`) installs everything. This page lists
exactly what the **installer** needs, what the **factory itself** is granted, and
what an **end user** needs, so it can be reviewed before anything is created.
Every name below starts with the install prefix (`sbx` by default); a second
install in the same tenancy uses another prefix.

```
tenancy
 └─ <parent compartment you choose>
     └─ sbx                      everything the product owns
         ├─ sbx-control          network, workers, control database + application, vault, sandbox stacks
         └─ sbx-sandboxes        every user sandbox, tagged with owner and expiry
```

## 1. The installer

**Who:** a tenancy administrator, once. The stack creates IAM policies and dynamic
groups in the tenancy root, which only an administrator (or a group with the
grants below) may do.

If you would rather not use a full administrator, the installing user's group needs:

```
allow group <installers> to manage compartments in tenancy
allow group <installers> to manage policies in tenancy
allow group <installers> to manage dynamic-groups in tenancy
allow group <installers> to manage tag-namespaces in tenancy
allow group <installers> to manage tag-defaults in tenancy
allow group <installers> to manage usage-budgets in tenancy
allow group <installers> to manage quota in tenancy
allow group <installers> to read limits in tenancy
allow group <installers> to manage all-resources in compartment <parent compartment>
allow group <installers> to manage orm-stacks in compartment <parent compartment>
allow group <installers> to manage orm-jobs in compartment <parent compartment>
```

plus, for their own user, the right to create an **auth token** (every user has it
by default). The stack creates one for the installer so the workers can push the
app images users build; a user may hold at most two.

**Account:** Pay-As-You-Go or paid. Free-tier trials cannot run paid Autonomous
Databases or Kafka clusters.

**Region:** any region subscribed by the tenancy that offers the services in
section 4. The IAM part is written in the home region automatically.

## 2. What the factory is granted (created by the stack)

Nothing is granted to a human user. All grants are to the factory's own
identities, scoped to the `sbx` tree except where a service needs tenancy scope.

**Workers** — dynamic group `sbx-worker-dg`: container instances in `sbx-control` (`foundation/worker.tf`)
```
allow dynamic-group sbx-worker-dg to manage all-resources in compartment id <sbx-sandboxes>
allow dynamic-group sbx-worker-dg to manage orm-stacks in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to manage orm-jobs in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to manage repos in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to manage compute-container-family in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to manage virtual-network-family in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to manage object-family in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to use vaults in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to use keys in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to use generative-ai-family in compartment id <sbx-control>
allow dynamic-group sbx-worker-dg to read objectstorage-namespaces in tenancy
allow dynamic-group sbx-worker-dg to read limits in tenancy
allow dynamic-group sbx-worker-dg to read repos in tenancy
allow dynamic-group sbx-worker-dg to inspect compartments in tenancy
allow dynamic-group sbx-worker-dg to inspect tenancies in tenancy
allow dynamic-group sbx-worker-dg to use tag-namespaces in tenancy
```
Why: they create and destroy each sandbox (Resource Manager stacks in control, the
resources in sandboxes), build app images, read service limits to fall back when a
limit is used up, and probe which chat models answer in the region.

**Code running inside a sandbox** — dynamic group `sbx-sandbox-adb-dg`: anything in `sbx-sandboxes` (`foundation/sandbox_workloads.tf`)
```
allow dynamic-group sbx-sandbox-adb-dg to use generative-ai-family in tenancy
allow dynamic-group sbx-sandbox-adb-dg to manage object-family in compartment id <sbx-sandboxes>
allow dynamic-group sbx-sandbox-adb-dg to manage dataflow-family in compartment id <sbx-sandboxes>
allow dynamic-group sbx-sandbox-adb-dg to manage data-catalog-family in compartment id <sbx-sandboxes>
allow dynamic-group sbx-sandbox-adb-dg to read compartments in tenancy
```

**The control database** (the application's assistant) — dynamic group `sbx-control-adb-dg` (`foundation/control_adb.tf`)
```
allow dynamic-group sbx-control-adb-dg to manage generative-ai-family in tenancy
```

**OCI services acting for a sandbox** (`foundation/sandbox_workloads.tf`, `functions_gateway.tf`, `secrets.tf`)
```
allow service apigateway to use virtual-network-family in tenancy
allow any-user to use functions-family in compartment id <sbx-sandboxes> where ALL {request.principal.type = 'ApiGateway', request.resource.compartment.id = '<sbx-sandboxes>'}
allow service dataflow to read buckets in compartment id <sbx-control>
allow service dataflow to read objects in compartment id <sbx-control>
allow service dataflow to read buckets in compartment id <sbx-sandboxes>
allow service dataflow to manage objects in compartment id <sbx-sandboxes>
allow any-user to manage object-family in compartment id <sbx-sandboxes> where ALL {request.principal.type = 'dataflowrun', request.principal.compartment.id = '<sbx-sandboxes>'}
allow any-user to read object-family in compartment id <sbx-sandboxes> where ALL {request.principal.type = 'datacatalog', request.principal.compartment.id = '<sbx-sandboxes>'}
allow any-user to read buckets in compartment id <sbx-sandboxes> where ALL {request.principal.type = 'datacatalog', request.principal.compartment.id = '<sbx-sandboxes>'}
allow service faas to read repos in tenancy
allow service faas to use apm-domains in tenancy
allow service rawfka to {SECRET_UPDATE} in compartment id <sbx-sandboxes>
allow service rawfka to use secrets in compartment id <sbx-sandboxes> where request.operation = 'UpdateSecret'
allow service rawfka to read secrets in compartment id <sbx-sandboxes>
allow service rawfka to use virtual-network-family in compartment id <sbx-control>
allow service rawfka to use virtual-network-family in compartment id <sbx-sandboxes>
```

**Oracle AI Data Platform** (optional, `enable_aidp`, `foundation/aidp.tf`) — the grants from Oracle's AIDP IAM guide, conditioned on `request.principal.type='aidataplatform'` (and `datalake` for Generative AI): inspect identity domains/users/groups, manage log groups and read logs in `sbx-sandboxes`, create/read buckets and manage the objects of buckets the AIDP instance governs, use tag namespaces, read the Object Storage namespace, use Generative AI.

## 3. End users

| To | Needs |
|---|---|
| Use the factory (chat, starters, build form, their sandboxes, destroy, change lifetime) | **only an application login** — no OCI account. The installer signs in with the `app_admin_user` / `app_admin_password` outputs and creates the others. Each user sees and controls only their own sandboxes. |
| Use what they built | the links and credentials on their sandbox card: app URL, SQL Developer Web / APEX / REST (through the sandbox's HTTPS gateway), Airflow login, Kafka bootstrap and superuser, function URLs, MCP endpoint. No OCI login. |
| Open a resource in the OCI console (Data Flow runs, Data Catalog, NoSQL table explorer, buckets) | optional: an OCI user in a group with `read all-resources in compartment sbx-sandboxes`. Only the console links need it. |
| Have their code deployed | a public Git URL (a folder link inside a repository works), or files attached in the chat. The factory builds inside OCI. |

## 4. Services and limits in the install region

**Services the region must offer:** Container Instances, Autonomous Database (23ai),
API Gateway, Resource Manager, Vault, Container Registry, Generative AI (on-demand
chat models), and for the matching sandbox types: Data Flow, Data Catalog, NoSQL,
Functions, Queue, Streaming with Apache Kafka, AI Data Platform.

**Generative AI models** differ by region, and a model can be listed and still not
serve on demand. The factory probes them at start (`factory/profile.py`) and offers
only the ones that answer; in `us-phoenix-1` that is 3 of 8 (Gemini 2.5 Flash,
Gemini 2.5 Pro, Grok 4.6). With none, chat and Select AI are switched off and
everything else still works.

**Service limits** (per region, Console > Governance > Limits). New tenancies start small:

| Limit | New-tenancy default | What it caps | Recommended |
|---|---|---|---|
| API Gateway `gateway-count` | 5 | one per sandbox with an app or functions; when used up, apps fall back to a public IP (HTTP) and the card says so | 50 |
| Data Catalog `catalog-count` | 2 | one per sandbox that asks for a catalog; without room the sandbox is built without one and says so | 10 |
| Autonomous Database ECPUs | varies | 2 ECPU per paid database (the control database is Always Free) | 64 |
| Container Instances cores / memory | varies | 1 OCPU per worker (3 by default) and per app container | 64 / 1 TB |
| Streaming with Apache Kafka clusters | varies | one per Kafka sandbox | 5 |

## 5. Install

**One click:** the **Deploy to Oracle Cloud** button in the README opens the stack
in Resource Manager. Fill in the parent compartment, prefix, your email, a
budget, and the application's first login (admin username and password; leave
the password empty to have one generated); Plan; Apply. Takes about 15 minutes.

**Or from a laptop:**
```
cd foundation
terraform init
terraform apply -var tenancy_ocid=... -var region=... -var owner=you@example.com -var budget_alert_email=you@example.com -var current_user_ocid=...
```

**Then:** open the `app_url` output and sign in with the admin username and
password you chose (both are also in the stack outputs `app_admin_user` /
`app_admin_password`). On their first start (a few minutes after the apply) the
workers create the application, load the assistant's prompts and detect the
region's AI models; until then the URL answers 404.

**Prove it (optional, recommended):** `python factory/run_tests_in_oci.py --kafka`
runs the full end-to-end suite inside OCI — every sandbox type, built, verified
and destroyed — and writes the report to a bucket.

### Developing the factory itself (not needed to install it)

We build and release the worker image with an OCI DevOps pipeline: `build_spec.yaml`
(build) → deliver to OCIR → `roll_spec.yaml` (roll the workers, one at a time, each
health-checked) → `e2e_spec.yaml` (the full suite; the pipeline fails if it fails).
It needs OCI Logging enabled on the DevOps project (runs fail at once without it)
and its own dynamic group with DevOps, repository and container-instance grants.
Installers never need any of this: the stack runs the published release image.

## 5a. Removing or reinstalling

Learned from a full reset of our own install (2026-09-25):

1. **Destroy the sandboxes first** (every user's, from the app or `sandbox_factory.py destroy`), then the stack.
   Resource Manager runs only a few jobs at once per tenancy; the factory waits for a slot.
2. **Destroy the stack** in Resource Manager (or `terraform destroy`). Expect:
   - the **vault** is only *scheduled* for deletion (7 days minimum), so its compartment stays until then;
   - **tags are deleted slowly** (about 10 minutes each) and the **tag namespace** after them. Its name is
     unique across the tenancy, so reinstalling with the **same prefix** must wait until it is gone;
   - rarely, a database's **private endpoint outlives the database** and pins its network security group,
     subnet and VCN. The endpoint belongs to the service and cannot be deleted by the tenancy; it is
     released by OCI later.
3. **To reinstall at once**, use a new prefix, or rename the old top compartment (for example
   `sbx` → `sbx-retired-<date>`) and wait for the tag namespace to disappear, then install.

## 6. Known limits (honest list)

- Isolation between users is at the application and network layer; inside OCI all
  sandboxes share one compartment and one dynamic group. `per_sandbox_compartment = true`
  gives IAM-level isolation at the cost of slower creates.
- Generated passwords are stored in the control database and shown on the owner's
  card. Move them to Vault before a wide rollout.
- Users are application accounts; SSO (OCI IAM identity domains) is an APEX
  authentication-scheme change, not yet done.
- One region per install (a second region is a second install with another prefix).
- Kafka's public endpoint add-on is unreliable through the Terraform provider
  (being moved to the SDK); the Data Catalog harvest registers the bucket but the
  harvest itself can fail inside the service.
