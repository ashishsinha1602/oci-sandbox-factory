# Sandbox Factory for Oracle Cloud

Self-service OCI sandboxes that build themselves from a chat and delete themselves
when their time is up.

A user describes what they need, in plain words or as an AWS-to-OCI mapping, or
hands over a Git folder. The factory plans it, prices it from Oracle's live price
list, and builds it in your tenancy with Terraform on Resource Manager. They get
links, credentials and logs on a card, and the sandbox is destroyed when its
lifetime ends, after 1 to 30 days.

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ashishsinha1602/oci-sandbox-factory/releases/latest/download/sandbox-factory-foundation.zip)

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

1. Read [docs/PREREQUISITES.md](docs/PREREQUISITES.md). You need a tenancy
   administrator and a Pay-As-You-Go or paid account.
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

## Licence

Copyright (c) 2026 Ashish Sinha. All rights reserved. You may install and use the
published release in your own tenancy, free of charge. You may not copy,
redistribute, resell or present it as your own. See [LICENSE](LICENSE). The
factory's source code is not public.
