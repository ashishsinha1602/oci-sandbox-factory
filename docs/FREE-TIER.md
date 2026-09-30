# Free Tier edition

Sandbox Factory installs on an **Oracle Cloud Free Tier account** (no payment method) as the
Free Tier edition. Pick **Edition: free** on the install form. Everything else is the same
one-click stack.

## What is different

| | Standard edition | Free Tier edition |
|---|---|---|
| Account | Pay As You Go or paid | Free Tier (Always Free resources only) |
| Workers | Container Instances (1 to 10) | One Always Free VM running the same worker image under podman: Arm `VM.Standard.A1.Flex` (2 OCPU, 12 GB; default) or x86 `VM.Standard.E2.1.Micro` (1 GB; fallback) |
| Assistant | OCI Generative AI | Google Gemini API with your own free key from [Google AI Studio](https://aistudio.google.com/apikey); without a key the one-click starters and the form still work |
| Sandboxes can build | Everything | An Always Free Autonomous Database (23ai, REST, in-database document search), NoSQL tables, Object Storage buckets, and, on the Arm VM, containerised applications |
| Applications | Their own Container Instance behind an HTTPS gateway | On the Arm VM: one podman pod per sandbox beside the worker, reached at `http://<vm public ip>:<port>` (ports 8101 to 8199, plain HTTP). Images are pulled or built on the VM; nothing goes to a registry. Not on the Micro VM (1 GB) |

## What a Free Tier account cannot have

These are not part of Always Free, so the factory says so instead of failing minutes later:

- Kafka (Streaming with Apache Kafka)
- Container Instances and API Gateway (applications run on the worker VM instead, HTTP only; extra container instances, `app_instances`, are declined)
- Functions
- Data Flow (Spark, Iceberg)
- Data Catalog
- Queue
- AI Data Platform
- A second sandbox database (Always Free allows two per tenancy; the factory's control database is one of them)
- Paid database tiers, and Select AI (OCI Generative AI)

The chat declines them with the free alternative. A request that still carries one of them is
refused before anything is built, with the same message on the card.

## Applications on the Arm VM

Grafana, the React and FastAPI starters, Streamlit, Studio, the MCP server, your own image or
repository: the worker builds or pulls the image on the VM and starts it in a pod for the sandbox.
The card shows `http://<vm public ip>:<port>`. The containers of one sandbox share localhost, get
the same injected variables as on the standard edition (database connection, buckets, NoSQL tables,
your own values), and are removed with the sandbox or when it expires. The VM is shared by every
sandbox of the install: 2 OCPUs and 12 GB in total, so keep applications small. There is no HTTPS on
these URLs; put your own domain and certificate in front if you need one.

## Limits to know

- Always Free resources live in your **home region**; install there.
- Always Free capacity is shared; a VM or database can be refused with "out of capacity" at busy
  times. Try again later, it is not a factory error.
- One free database slot is left after the control database, so one database sandbox at a time.
  Destroy it (or let it expire) before creating the next.
- Free Tier tenancies are limited to 2 VCNs; the factory uses one.

## Upgrading later

Upgrade the tenancy to Pay As You Go, then install the standard edition with a new prefix. The
Free Tier install can be destroyed from Resource Manager like any stack.
