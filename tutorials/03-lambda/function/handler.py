"""
The Lambda function itself.

This file is what actually runs inside AWS. Everything else in this tutorial
exists only to package it, ship it, and call it.

A handler takes exactly two arguments:

  event    the input, already parsed from JSON into a Python dict
  context  information about this particular run, supplied by the runtime

Whatever you return is serialised back to JSON and handed to the caller.
"""

import os


def handler(event, context):
    # Raising is how a Lambda reports failure. The runtime catches it, and the
    # caller sees FunctionError with the exception type and a stack trace.
    if event.get("boom"):
        raise ValueError("deliberate failure, triggered by the caller")

    # print() goes to CloudWatch Logs. There is no console attached to a
    # Lambda, so this is your only window into what happened.
    print(f"invoked with event: {event}")

    name = event.get("name", "world")

    return {
        "greeting": f"hello {name}",
        # Configuration arrives as environment variables, never hardcoded.
        # This is how the same code artifact runs in dev and in prod.
        "stage": os.environ.get("STAGE", "unset"),
        # The context object knows how long before this run is killed.
        # Real code uses this to bail out cleanly instead of being cut off.
        "remaining_ms": context.get_remaining_time_in_millis(),
    }
