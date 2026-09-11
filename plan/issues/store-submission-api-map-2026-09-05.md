# Store submission API, mapped end to end (order 776-g6r3, exit criterion 2)

Author: yolanda (windows), 2026-09-05. Sources are Microsoft Learn pages fetched
on that date; each is linked at the point it is used. **Nothing in this document
was executed** — see "What is NOT verified" at the bottom. It is the map EC2
asks for, not a report of a run.

## Which API — and the confusion that would cost a day

Two different Microsoft APIs are both called "the Store submission API", and the
docs for both rank highly for the same searches:

| | MSIX / UWP (**ours**) | MSI / EXE |
|---|---|---|
| Base URI | `https://manage.devcenter.microsoft.com/v1.0/my/...` | `https://api.store.microsoft.com/...` |
| Token `resource` / scope | `https://manage.devcenter.microsoft.com` | `https://api.store.microsoft.com/.default` |
| Docs | [Create and manage submissions](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services) | [Store submission API for MSI or EXE app](https://learn.microsoft.com/en-us/windows/apps/publish/store-submission-api) |

The operator's listing is **MSIX** (their 2026-09-02 decision: the EXE/MSI draft
was deleted and a new MSIX-type listing created). So the left column applies, and
the `.default`-scoped token that most search results surface first is the WRONG
one for us. A token minted against the wrong resource authenticates fine and then
fails on every call.

## Prerequisites — all one-time, all operator actions

From [Create and manage submissions](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services):

1. An Azure AD directory, with **Global administrator** permission on it. If the
   operator has no directory, one can be created in Partner Center at **no
   additional charge**.
2. Associate the Partner Center account with that Azure AD directory.
3. Add an Azure AD application to Partner Center's **Users** page and assign it
   the **Manager** role. Copy the **Tenant ID** and **Client ID**.
4. **Add new key** and copy the key value — *the docs state it cannot be
   retrieved again after leaving that page*.

**The API cannot create the app.** The listing must already exist in Partner
Center (it does), and — the constraint that matters for sequencing —
**one submission must have been completed manually in Partner Center first,
including the age-ratings questionnaire**, before the API can create any
submission for that app. This independently corroborates the previous agent's
recommendation of a manual first submission: it is not merely prudent, it is
required by the API's own prerequisites.

## Step 1 — token

```
POST https://login.microsoftonline.com/<tenant_id>/oauth2/token
Content-Type: application/x-www-form-urlencoded; charset=utf-8

grant_type=client_credentials
&client_id=<your_client_id>
&client_secret=<your_client_secret>
&resource=https://manage.devcenter.microsoft.com
```

Token lifetime is **60 minutes**; refresh by repeating the same call. It goes in
the `Authorization` header of every subsequent call.

## Step 2 — the submission sequence

From [Manage app submissions](https://learn.microsoft.com/en-us/windows/uwp/monetize/manage-app-submissions).
All paths are relative to `https://manage.devcenter.microsoft.com/v1.0/my`.

| # | Verb | Path | Purpose |
|---|------|------|---------|
| 1 | POST | `/applications/{applicationId}/submissions` | Create a submission. Response carries the submission JSON **and `fileUploadUrl`** |
| 2 | PUT | `/applications/{applicationId}/submissions/{submissionId}` | Update the submission (packages, listings, metadata) |
| 3 | — | *(Azure Blob)* | **PUT the ZIP to the `fileUploadUrl` SAS URI** |
| 4 | POST | `/applications/{applicationId}/submissions/{submissionId}/commit` | Commit — tells Partner Center the submission is complete |
| 5 | GET | `/applications/{applicationId}/submissions/{submissionId}/status` | Poll until terminal |

Supporting: `GET /applications/{applicationId}/submissions/{submissionId}` reads
a submission back; `DELETE` on the same path removes it.

**The upload is not a multipart POST to the API.** `fileUploadUrl` is an Azure
Blob Storage **shared access signature URI**, and the packages plus listing
images go up as a **single ZIP archive** written to that blob. Any HTTP client
that can PUT to a SAS URI will do; the docs' examples use the Azure Storage
client libraries, but nothing requires them.

## Step 3 — how you know it worked

Poll `.../status` and read `status`. The documented values:

- In flight: `PendingCommit` -> `CommitStarted` -> `PreProcessing` ->
  `Certification` -> `Release` -> **`Published`**
- Terminal failures: `CommitFailed`, `PreProcessingFailed`,
  `CertificationFailed`, `PublishFailed`, `Canceled`
- `statusDetails` carries the error specifics

The immediate signal after commit is `CommitStarted` moving to `PreProcessing`
(accepted) or `CommitFailed` (rejected). **`Published` is the only success
state**; a CI job that treats "not failed" as success will report green while a
submission sits in `Certification` for days.

Gradual rollout has its own endpoints (`/packagerollout`,
`/updatepackagerolloutpercentage`, `/haltpackagerollout`,
`/finalizepackagerollout`) if staged release is ever wanted.

## Costs and lead times

- **API cost: $0.** No certificate is required — Microsoft re-signs on ingestion.
  Both Partner Center registration fees are already waived (per this packet's
  research note), and creating an Azure AD directory in Partner Center is free.
- **Certification: typically a few hours, up to three business days**
  ([app certification process](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-certification-process)).
  Content compliance is the variable part — it scales with visual content and
  with how many apps were submitted recently, so the number is not a constant a
  release job can budget against.
- **Visible to customers: ~15 minutes after certification passes**, varying by
  region.
- Practical consequence: **a Store release is not same-hour reliable.** Any
  release process that blocks on `Published` must tolerate a three-business-day
  worst case, or decouple the Store submission from the release it accompanies.

## Traps, each of which invalidates a run

1. **Never edit an API-created submission in Partner Center.** The docs are
   explicit: do so and you can no longer change or commit it via the API, and it
   may be left in an error state recoverable only by deleting and recreating.
   This forbids the obvious debugging move of "just fix it in the UI".
2. **Pricing Version 2 is a hard block for pricing changes.** If the listing has
   a **Review price per market** button under Pricing and availability, the API
   returns an unknown tier for the pricing part. Other modules still work. Worth
   checking on the operator's listing before automating anything price-adjacent.
3. **409 on mandatory app updates or Store-managed consumable add-ons.** Neither
   applies to us today; both would force submissions back into Partner Center.
4. **Not usable for LOB or volume-purchase distribution.** Not our channel.

## StoreBroker — evaluate before writing a client

Microsoft ships [StoreBroker](https://github.com/Microsoft/StoreBroker), an
open-source PowerShell module implementing a CLI over this exact API, and states
it is "actively used within Microsoft as the primary way that many first-party
applications are submitted to the Store".

This is worth a hard look before we write anything: the Windows build path is
**already PowerShell** (`scripts/build-windows-tray.ps1`), so StoreBroker lands
in the language the lane already speaks. The counter-argument is dependency
weight and the module's own maintenance status, which I have **not** assessed —
naming that as unmeasured rather than recommending on vibes.

## What needs the operator, exactly

Nothing below can be done by an agent; each is an account action on the
operator's identity.

| # | Action | Cost |
|---|--------|------|
| 1 | Confirm/create an Azure AD directory and hold Global administrator on it | $0 |
| 2 | Associate Partner Center with that directory | $0 |
| 3 | Create the Azure AD application in Partner Center, assign it **Manager** | $0 |
| 4 | Generate the key and store it where CI can reach it (**one-time visibility**) | $0 |
| 5 | Complete **one manual submission**, including age ratings | time only |

Only after 5 does the API become usable for this app at all.

## What is NOT verified

- **No call was made.** No token minted, no submission created, no ZIP uploaded,
  no status polled. Every endpoint, parameter and status value here is quoted
  from the linked docs, not observed.
- **No measured lead time.** The hours-to-three-days figure is Microsoft's
  published range, not our observation. EC2 asks for lead times *recorded*; the
  recorded-from-a-real-submission number can only come after operator step 5.
- **StoreBroker is unevaluated** as a dependency.
- Docs age. Each link carries the date it was read (2026-09-05); re-read before
  relying on a parameter, particularly the `resource` value, which is the one
  most likely to move as the two APIs converge.
