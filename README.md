# Sandbox Factory for Oracle Cloud

Self-service OCI sandboxes that build themselves from a chat and delete themselves
when their time is up.

A user describes what they need, in plain words or as an AWS-to-OCI mapping, or
hands over a Git folder. The factory plans it, prices it from Oracle's live price
list, and builds it in your tenancy with Terraform on Resource Manager. They get
links, credentials and logs on a card, and the sandbox is destroyed when its
lifetime ends, after 1 to 30 days.

**Two-minute demo:** https://www.youtube.com/watch?v=nuHfzOqG4io

Also on the [Terraform Registry](https://registry.terraform.io/modules/ashishsinha1602/sandbox-factory/oci/latest) as `ashishsinha1602/sandbox-factory/oci`.

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ashishsinha1602/oci-sandbox-factory/releases/latest/download/sandbox-factory-foundation.zip)

**Oracle Cloud Free Tier account (no card)?** Use this button instead; it installs the Free Tier edition on Always Free resources: databases, NoSQL, buckets, and applications on the free Arm VM. See [FREE-TIER](docs/FREE-TIER.md) for what it can and cannot build.

[![Deploy to Oracle Cloud, Free Tier](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ashishsinha1602/oci-sandbox-factory/releases/latest/download/sandbox-factory-foundation-free.zip)

## After the apply is green

Terraform builds the infrastructure; the application is installed by the worker on its
**first start, a few minutes later** (up to 10 on the Free Tier edition, where the worker
VM first installs podman and pulls the image). Until then the application URL shows 404.
That is normal. The stack outputs give you:

- `app_url`: the application, sign in with `app_admin_user` / `app_admin_password`
- `status_url`: install progress as JSON, from the worker's first minute on
- `next_step`: the same advice, in the outputs panel

## What it builds

| Ask for | You get |
|---|---|
| A database to explore or to wire into agents | Autonomous Database with Select AI and REST, the Studio chat UI, an MCP endpoint |
| Your app from a Git folder with a Dockerfile | The image built inside OCI and served on HTTPS |
| An AWS Lambda, or any small handler | An OCI Function, with Lambda code run unchanged, optionally on a schedule |
| A Glue or Spark job | A Data Flow application, optionally writing Iceberg tables to Object Storage, plus a query application to read them |
| An Airflow + Spark pipeline | Airflow with your DAGs loaded, Data Flow, Data Catalog, the gold tables in Oracle |
| Queues, NoSQL, Kafka, buckets | OCI Queue, NoSQL tables, a Streaming with Apache Kafka cluster, Object Storage |

The assistant builds the design you name, and nothing you did not ask for. It
writes the code when you describe it and have none, and it shows the monthly
cost of every part before anything is created.

## Install

1. Read [docs/PREREQUISITES.md](docs/PREREQUISITES.md). The install is run once by a
   tenancy administrator (or a group with the listed grants) on a Pay-As-You-Go or
   paid account; users need no OCI account afterwards. Your security team's questions
   are answered in [docs/SECURITY.md](docs/SECURITY.md).
2. Click **Deploy to Oracle Cloud**. Choose a parent compartment, a prefix, a
   budget, and the application's admin username and password.
3. Apply. It takes about 15 minutes. Open the `app_url` output and sign in.

Everything runs in your tenancy. No data leaves it, and no one outside it has
access.

## Try it

- `examples/telemetry-pipeline`: Airflow + Spark, "move this to OCI".
- `examples/hello-lambda`: plain AWS Lambda code that becomes an OCI Function.
- `examples/hello-app`, `examples/orders-app`: apps with a Dockerfile.

Paste a folder link into the chat, for example
`https://github.com/ashishsinha1602/oci-sandbox-factory/tree/main/examples/telemetry-pipeline`.

## Uninstall

1. Destroy your sandboxes first, from the application (each card's **Destroy**) or let them expire.
   Their images, buckets and databases go with them.
2. In Resource Manager, open the Sandbox Factory stack and run **Destroy**. Compartments are deleted last
   and can take a few minutes; if the job reports a compartment still active, run **Destroy** again.
3. The standard edition's vault is scheduled for deletion (at least 7 days), as Oracle requires.

## Licence

Apache License 2.0. Copyright 2026 Ashish Sinha. Install it, run it, change it, ship it; see [LICENSE](LICENSE).
The full source of the worker and the application is public at
https://github.com/ashishsinha1602/oci-sandbox-factory-src, and every release image is built from a tagged commit of it.