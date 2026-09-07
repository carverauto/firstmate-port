# Captain calls

When firstmate has a question for the captain, it should not land in Discord as
a wall of text ending in "reply with A, B or C". A captain call is that same
question posted as an interactive form: a select menu the captain picks from,
optionally with a "Something else..." choice that opens a modal to type into.

The pick comes back through the interactions endpoint this app already serves,
is recorded against the question, and is filed into the tenant's inbox as an
ordinary captain order. The crew reads it with the command it already uses:

```sh
fm-steer inbox next --task fm-port
```

Nothing new polls Discord, and no bot process runs anywhere. The portal is the
only thing that talks to Discord, in both directions.

## The round trip

```
firstmate            portal                     Discord              captain
    |                   |                          |                    |
    |-- POST /api/captain/calls ->                 |                    |
    |                   |-- row (status: open) --> |                    |
    |                   |-- POST message + select ->                    |
    |                   |<-- message id ----------|                     |
    |<-- 201 call ------|                          |--- select menu --->|
    |                   |                          |<-- picks "Hold" ---|
    |                   |<- POST /interactions (signed, MESSAGE_COMPONENT)
    |                   |-- row (status: answered)                      |
    |                   |-- inbox order on the call's task              |
    |                   |-- UPDATE_MESSAGE: question becomes the answer >|
    |<- fm-steer inbox next --task fm-port         |                    |
```

## Asking

`POST /api/captain/calls` takes a bearer token - an agent API key or a
`fm-steer auth login` device token - and the tenant comes from the signed-in
caller, never from the request.

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{
        "question": "PR #108 is green. Ship it?",
        "channel_id": "123456789012345678",
        "task": "fm-port",
        "allow_other": true,
        "options": [
          {"value": "ship",  "label": "Ship it", "description": "Merge and tag"},
          {"value": "hold",  "label": "Hold",    "description": "Wait for me"},
          {"value": "abort", "label": "Abort",   "description": "Close the PR"}
        ]
      }' \
  https://$HOST/api/captain/calls
```

| Field | Required | What it is |
| --- | --- | --- |
| `question` | yes | The message body. At most 2000 characters, which is Discord's own limit. |
| `channel_id` | yes | The Discord channel to post in. Public routing data, not a credential - the caller supplies it. |
| `options` | yes | 1-25 choices (at most 24 with `allow_other`) of `value`, `label`, and optional `description`. Values must be unique; `__other__` is reserved. Each value, label, and supplied description must be nonblank and at most 100 characters. |
| `task` | no | The inbox task the answer is filed under. Defaults to `firstmate`. |
| `allow_other` | no | Adds a "Something else..." choice that opens a modal. Default false. |

`201` returns the call, including the `message_id` when Discord returned one.
If an answer commits before a delivery failure is handled, the response is
still `201` with the answered call; its message ID may be empty.
`422` reports validation or persistence errors. Invalid choices are refused
before posting. `502` returns an `error` and a nested `call` with
`status: "failed"` and a `delivery_error` naming what to fix. A transport
timeout does not prove Discord failed to display the message.
There is no call-history GET API; read answers through the inbox.

### The bot token

Posting uses the tenant's `discord`/`bot_token` credential, stored in the portal
like every other secret (see [credentials.md](credentials.md)). It is read fresh
on every message, so rotating it in the portal takes effect immediately, and it
is never written into application environment or a cluster secret.

The bot has to be in the channel it is posting to. A `502` reading
`Discord refused (403, code 50001) - is the bot in that channel?` is that, not a
token problem.

## Answering

Store the captain’s Discord user ID in the tenant’s `discord`/`captain_user_id` credential slot. Only that ID may select an answer, open the modal, or submit it. Missing or unreadable credentials refuse everyone with an ephemeral response.

The captain picks in Discord. Nothing else has to happen: the interaction is
signed by the tenant's Discord application, arrives at the same
`POST /interactions` every other interaction uses, and is verified exactly the
same way.

* **A pick** records the answer, files the inbox order, and edits the original
  message so the question shows the answer and the select is gone. Clicking a
  second time changes nothing and says "Already answered" to whoever clicked,
  privately.
* **"Something else..."** opens a modal. Nothing is recorded until it is
  submitted; the answer is then the captain's own text, labelled
  `Something else`.
* **A select value that was not one of the options** is refused. Selected
  values are stored exactly, including surrounding whitespace. Free text is
  accepted only when `allow_other` is set; modal text is trimmed.
* **A call belonging to another tenant** is not found. The endpoint has already
  resolved the signature to one tenant, and only that tenant's calls are
  reachable.

The order filed in the inbox looks like this:

```
Captain answered: Hold

Question: PR #108 is green. Ship it?
Value: hold
Answered by: Captain
Call: 01a079f8-7ad7-7f3e-be91-b2859e031a79
```

## What this does not do

* It does not register slash commands. A captain call is a message the portal
  posts, not a command anybody types.
* It does not claim every component interaction. Only `custom_id`s beginning
  `fm:ask:` are ours; anything else on the application still goes to
  `<tenant>.discord.inbound` exactly as before, so an application shared with
  another bot keeps working.
* It does not retry. A question the captain never asked for, arriving twice, is
  worse than one that failed where the crew could see it.

## Why a table

A question the captain has not answered yet outlives the request that asked it,
the node that served it, and often the day. The Discord message carrying it
outlives all three. So the call is a row - the same argument the inbox makes in
[inbox.md](inbox.md) - and the `custom_id` on the message is that row's id, which
is what lets an answer given an hour later still land on the question it was
asked about.

Answering is a one-way door, and what enforces it is a `status == :open` filter
carried into the UPDATE itself rather than a read followed by a write. Two
clicks a millisecond apart both read an open call; only one of them updates one,
and the other is told it was already answered.

Delivery failure also updates only an open row; it cannot overwrite a committed
answer. The delivery path re-reads and returns that answered call as success.

The answer transition and inbox order commit in one transaction. A failed insertion leaves the call open for retry. The Discord update shortens the question as needed to preserve the answer within 2000 characters; modal answers are limited to 1000 characters.
